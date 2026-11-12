// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 SIP Phone contributors

#import "PJBridge.h"
#include <pjsua2.hpp>
#include <os/log.h>
#include <map>
#include <memory>
#include <string>

using namespace pj;

@interface PJBridge ()
- (void)handleRegCode:(int)code reason:(const std::string &)reason;
- (void)handleIncoming:(int)callId wholeMsg:(const std::string &)msg;
- (void)handleCallState:(int)callId;
- (void)applyMuteToCapture;
- (void)endAllCallsWithReason:(NSString *)reason;
- (void)reportMediaOfCall:(int)callId streamInfo:(const StreamInfo &)si;
@end

NSString *const PJBridgeErrorDomain = @"PJSIP";

/// Status code plus PJSIP reason text. Never include the digits.
static NSError *PJStatusError(pj_status_t status, const std::string &reason) {
    NSString *r = [NSString stringWithUTF8String:reason.c_str()] ?: @"unknown error";
    return [NSError errorWithDomain:PJBridgeErrorDomain code:status
                           userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ [status %d]", r, (int)status]}];
}

class BridgeAccount : public Account {
public:
    explicit BridgeAccount(PJBridge *owner) : owner_(owner) {}
    void onRegState(OnRegStateParam &prm) override { [owner_ handleRegCode:prm.code reason:prm.reason]; }
    void onIncomingCall(OnIncomingCallParam &prm) override { [owner_ handleIncoming:prm.callId wholeMsg:prm.rdata.wholeMsg]; }
private:
    __unsafe_unretained PJBridge *owner_;   // the bridge owns (and outlives) its account
};

class BridgeCall : public Call {
public:
    BridgeCall(Account &acc, int callId, PJBridge *owner) : Call(acc, callId), owner_(owner) {}
    void onCallState(OnCallStateParam &) override { [owner_ handleCallState:getId()]; }
    void onCallMediaState(OnCallMediaStateParam &) override {
        try {
            CallInfo ci = getInfo();
            for (unsigned i = 0; i < ci.media.size(); i++) {
                if (ci.media[i].type == PJMEDIA_TYPE_AUDIO && ci.media[i].status == PJSUA_CALL_MEDIA_ACTIVE) {
                    AudioMedia *aud = static_cast<AudioMedia *>(getMedia(i));
                    AudDevManager &mgr = Endpoint::instance().audDevManager();
                    aud->startTransmit(mgr.getPlaybackDevMedia());
                    mgr.getCaptureDevMedia().startTransmit(*aud);
                    if (toneGen_) { try { toneGen_->startTransmit(*aud); } catch (Error &) {} }   // re-INVITE: new port
                    try { [owner_ reportMediaOfCall:getId() streamInfo:getStreamInfo(i)]; } catch (Error &) {}
                }
            }
        } catch (Error &) {}
        [owner_ applyMuteToCapture];
    }

    /// In-band DTMF: a per-call tone generator connected to the call's active audio port.
    void playInband(const std::string &digits) {
        AudioMedia *aud = nullptr;
        CallInfo ci = getInfo();
        for (unsigned i = 0; i < ci.media.size(); i++) {
            if (ci.media[i].type == PJMEDIA_TYPE_AUDIO && ci.media[i].status == PJSUA_CALL_MEDIA_ACTIVE) {
                aud = static_cast<AudioMedia *>(getMedia(i)); break;
            }
        }
        if (!aud) throw Error(PJ_EINVALIDOP, "playInband", "No active audio media", __FILE__, __LINE__);
        if (!toneGen_) {
            std::unique_ptr<ToneGenerator> gen(new ToneGenerator);
            // Same clock rate as the conference bridge (slot 0 is the sound device port).
            pjsua_conf_port_info bridgeInfo;
            unsigned rate = pjsua_conf_get_port_info(0, &bridgeInfo) == PJ_SUCCESS ? bridgeInfo.clock_rate : 16000;
            gen->createToneGenerator(rate, 1);
            gen->startTransmit(*aud);
            toneGen_ = std::move(gen);
        }
        ToneDigitVector v;
        for (char c : digits) {
            ToneDigit d; d.digit = c; d.on_msec = 160; d.off_msec = 100; d.volume = 0;
            v.push_back(d);
        }
        toneGen_->playDigits(v);
    }
private:
    __unsafe_unretained PJBridge *owner_;
    std::unique_ptr<ToneGenerator> toneGen_;   // destroyed (unregistered from the bridge) with the call
};

@implementation PJBridge {
    std::unique_ptr<Endpoint> _ep;
    std::unique_ptr<BridgeAccount> _acc;
    std::map<int, std::unique_ptr<BridgeCall>> _calls;
    NSTimer *_timer;
    std::string _host, _user, _password;
    BOOL _muted;
}

+ (NSString *)version { return [NSString stringWithUTF8String:pj_get_version()]; }

static NSError *PJError(const std::string &msg) {
    return [NSError errorWithDomain:@"PJBridge" code:1 userInfo:@{NSLocalizedDescriptionKey: @(msg.c_str())}];
}

- (void)dealloc { [self shutdown]; }

/// Logs every codec PJSIP offers with its priority once at startup (codec ids only, nothing user-specific),
/// e.g. "codecs: G722/16000/1=255 PCMA/8000/1=254 PCMU/8000/1=253"; a priority of 0 means disabled.
+ (void)logCodecPriorities:(const CodecInfoVector2 &)codecs {
    static os_log_t log = os_log_create("com.aarneaarebye.sipphone", "sip");
    std::string line;
    for (const CodecInfo &ci : codecs) {
        if (!line.empty()) line += " ";
        line += ci.codecId + "=" + std::to_string((unsigned)ci.priority);
    }
    os_log(log, "codecs: %{public}s", line.empty() ? "(none)" : line.c_str());
}

- (BOOL)startAndReturnError:(NSError **)error {
    if (_ep) return YES;
    try {
        _ep.reset(new Endpoint);
        _ep->libCreate();
        EpConfig cfg;
        cfg.uaConfig.threadCnt = 0;              // we pump events from the main thread
        cfg.uaConfig.mainThreadOnly = true;
        cfg.uaConfig.userAgent = "SipPhone";
        // Level 2 (errors + warnings) and no SIP message dump, so credentials/auth headers are never logged.
        cfg.logConfig.level = 2; cfg.logConfig.consoleLevel = 2;
        cfg.logConfig.msgLogging = 0;
        cfg.medConfig.threadCnt = 1;
        _ep->libInit(cfg);
        TransportConfig tcfg; tcfg.port = 0;
        _ep->transportCreate(PJSIP_TRANSPORT_UDP, tcfg);
        _ep->libStart();
        try { _ep->audDevManager().setEcOptions(256, 0); } catch (Error &) {}   // echo cancellation
        // Codecs: G.722, PCMA, PCMU only (priority 0 disables the rest)
        for (const CodecInfo &ci : _ep->codecEnum2()) {
            pj_uint8_t prio = 0;
            if (ci.codecId == "G722/16000/1") prio = 255;
            else if (ci.codecId == "PCMA/8000/1") prio = 254;
            else if (ci.codecId == "PCMU/8000/1") prio = 253;
            _ep->codecSetPriority(ci.codecId, prio);
        }
        [PJBridge logCodecPriorities:_ep->codecEnum2()];
        __weak PJBridge *weakSelf = self;
        _timer = [NSTimer timerWithTimeInterval:0.02 repeats:YES block:^(NSTimer *) {
            PJBridge *s = weakSelf;
            if (s && s->_ep) { try { s->_ep->libHandleEvents(0); } catch (...) {} }
        }];
        [[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
        return YES;
    } catch (Error &e) {
        if (error) *error = PJError(e.info());
        try { if (_ep) _ep->libDestroy(); } catch (...) {}
        _ep.reset();
        return NO;
    }
}

- (BOOL)registerAccountWithHost:(NSString *)host user:(NSString *)user password:(NSString *)password error:(NSError **)error {
    if (!_ep) { if (error) *error = PJError("Engine not started"); return NO; }
    const char *h = host.UTF8String, *u = user.UTF8String, *p = password.UTF8String;
    if (!h || !u || !p) { if (error) *error = PJError("Invalid account data"); return NO; }
    // Same account: refresh the registration in place. Live calls reference the account and must survive
    // network changes, wake and Settings saves, so only a real account change ends them.
    if (_acc && _host == h && _user == u && _password == p) {
        try { _acc->setRegistration(true); return YES; }
        catch (Error &) { /* fall back to recreating the account */ }
    }
    try {
        [self endAllCallsWithReason:@"Account replaced"];   // calls reference the account: end them first
        _acc.reset();
        _host = h; _user = u; _password = p;
        AccountConfig ac;
        ac.idUri = "sip:" + _user + "@" + _host;
        ac.regConfig.registrarUri = "sip:" + _host;
        ac.regConfig.timeoutSec = 300;
        ac.regConfig.retryIntervalSec = 0;       // AppCore owns reconnect/backoff; no pjsua-internal retry
        ac.sipConfig.authCreds.push_back(AuthCredInfo("digest", "*", _user, 0, _password));
        _acc.reset(new BridgeAccount(self));
        _acc->create(ac);
        return YES;
    } catch (Error &e) {
        _acc.reset();
        if (error) *error = PJError(e.info());
        return NO;
    }
}

/// Defensive: only digits, '*', '#' and one leading '+' may reach the SIP URI.
static bool IsDialable(const char *s) {
    if (!s || !*s) return false;
    if (*s == '+') s++;
    if (!*s) return false;
    for (; *s; s++) {
        char c = *s;
        if (!((c >= '0' && c <= '9') || c == '*' || c == '#')) return false;
    }
    return true;
}

- (void)unregisterAccount {
    // Destroying the account unregisters it; callbacks from a dying account are ignored (_acc is null).
    [self endAllCallsWithReason:@"Account removed"];
    try { _acc.reset(); } catch (...) {}
    _password.clear();
}

- (nullable NSNumber *)dial:(NSString *)number error:(NSError **)error {
    if (!IsDialable(number.UTF8String)) { if (error) *error = PJError("Invalid number"); return nil; }
    if (!_acc) { if (error) *error = PJError("Not registered"); return nil; }
    const char *clean = [number stringByReplacingOccurrencesOfString:@"#" withString:@"%23"].UTF8String;
    if (!clean) { if (error) *error = PJError("Invalid number"); return nil; }
    try {
        std::unique_ptr<BridgeCall> call(new BridgeCall(*_acc, PJSUA_INVALID_ID, self));
        CallOpParam prm(true);
        call->makeCall("sip:" + std::string(clean) + "@" + _host, prm);
        int id = call->getId();
        _calls[id] = std::move(call);
        // pjsua2 cannot route callbacks fired inside makeCall (the Call is not yet bound to its pjsua call),
        // so deliver the current state once now; this also reports an immediately failed call as "ended"
        // and schedules its deferred erase.
        [self handleCallState:id];
        return @(id);
    } catch (Error &e) {
        if (error) *error = PJError(e.info());
        return nil;
    }
}

/// Best effort: value of the P-Called-Party-ID header of the INVITE (raw, parsed in Swift), or nil.
static NSString *CalledPartyHeader(const std::string &msg) {
    NSString *m = [NSString stringWithUTF8String:msg.c_str()];
    if (!m) return nil;
    NSRange head = [m rangeOfString:@"\r\n\r\n"];
    NSString *headers = head.location == NSNotFound ? m : [m substringToIndex:head.location];
    for (NSString *line in [headers componentsSeparatedByString:@"\r\n"]) {
        if ([line rangeOfString:@"P-Called-Party-ID:" options:NSCaseInsensitiveSearch | NSAnchoredSearch].location != NSNotFound) {
            NSString *v = [[line substringFromIndex:[line rangeOfString:@":"].location + 1]
                           stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            return v.length ? v : nil;
        }
    }
    return nil;
}

- (void)handleIncoming:(int)callId wholeMsg:(const std::string &)msg {
    if (!_acc) return;
    try {
        std::unique_ptr<BridgeCall> call(new BridgeCall(*_acc, callId, self));
        CallInfo info = call->getInfo();
        NSString *remote = @(info.remoteUri.c_str());
        // P-Called-Party-ID if the box sends it, else the To URI (the number that was dialled).
        NSString *called = CalledPartyHeader(msg) ?: @(info.localUri.c_str());
        try { CallOpParam ringing; ringing.statusCode = PJSIP_SC_RINGING; call->answer(ringing); } catch (...) {}
        _calls[callId] = std::move(call);
        [self.delegate incomingCall:callId from:remote called:called];
    } catch (...) {}
}

- (void)handleCallState:(int)callId {
    auto it = _calls.find(callId);
    if (it == _calls.end()) return;
    CallInfo ci;
    try { ci = it->second->getInfo(); } catch (...) { return; }
    NSString *state = nil;
    switch (ci.state) {
        case PJSIP_INV_STATE_CALLING: state = @"calling"; break;
        case PJSIP_INV_STATE_EARLY: state = @"ringing"; break;
        case PJSIP_INV_STATE_CONFIRMED: state = @"connected"; break;
        case PJSIP_INV_STATE_DISCONNECTED: state = @"ended"; break;
        default: break;
    }
    if (!state) return;
    [self.delegate callStateChanged:callId state:state statusCode:ci.lastStatusCode reason:@(ci.lastReason.c_str())];
    if (ci.state == PJSIP_INV_STATE_DISCONNECTED) {
        // never delete a Call inside its own callback
        __weak PJBridge *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{ PJBridge *s = weakSelf; if (s) s->_calls.erase(callId); });
    }
}

- (void)handleRegCode:(int)code reason:(const std::string &)reason {
    if (!_acc || code < 200) return;             // only final results
    [self.delegate registrationChanged:code reason:@(reason.c_str())];
}

- (void)answer:(NSInteger)callId {
    auto it = _calls.find((int)callId); if (it == _calls.end()) return;
    try { CallOpParam prm; prm.statusCode = PJSIP_SC_OK; it->second->answer(prm); } catch (...) {}
}

- (void)hangup:(NSInteger)callId {
    auto it = _calls.find((int)callId); if (it == _calls.end()) return;
    // 603 Decline for an unanswered incoming call; pjsua sends CANCEL/BYE as appropriate otherwise
    try { CallOpParam prm; prm.statusCode = PJSIP_SC_DECLINE; it->second->hangup(prm); } catch (...) {}
}

- (void)setMuted:(BOOL)muted { _muted = muted; [self applyMuteToCapture]; }

- (void)applyMuteToCapture {
    if (!_ep) return;
    // pjsua2 naming is inverted relative to pjsua: AudioMedia::adjustTxLevel() maps to pjsua_conf_adjust_rx_level()
    // (signal received FROM this port INTO the bridge), which is the microphone direction. Verified in the
    // pjsua2 header docs and in the linked media.o (adjustTxLevel -> _pjsua_conf_adjust_rx_level).
    try { _ep->audDevManager().getCaptureDevMedia().adjustTxLevel(_muted ? 0.0f : 1.0f); } catch (...) {}
}

- (BOOL)sendDTMF:(NSString *)digits callId:(NSInteger)callId method:(PJDTMFMethod)method error:(NSError **)error {
    auto it = _calls.find((int)callId);
    if (it == _calls.end()) { if (error) *error = PJStatusError(PJ_ENOTFOUND, "Call not found in engine"); return NO; }
    const char *d = digits.UTF8String;
    if (!d || !*d) { if (error) *error = PJStatusError(PJ_EINVAL, "No digits"); return NO; }
    try {
        switch (method) {
            case PJDTMFMethodRFC2833:
                it->second->dialDtmf(std::string(d));
                break;
            case PJDTMFMethodSIPInfo: {
                CallSendDtmfParam prm;
                prm.method = PJSUA_DTMF_METHOD_SIP_INFO;
                prm.digits = std::string(d);
                it->second->sendDtmf(prm);
                break;
            }
            case PJDTMFMethodInband:
                it->second->playInband(std::string(d));
                break;
            default:
                if (error) *error = PJStatusError(PJ_EINVAL, "Unknown DTMF method");
                return NO;
        }
        return YES;
    } catch (Error &e) {
        if (error) *error = PJStatusError(e.status, e.reason);   // reason is pj_strerror text, not the digits
        return NO;
    } catch (...) {
        if (error) *error = PJStatusError(PJ_EUNKNOWN, "Unexpected exception");
        return NO;
    }
}

- (void)reportMediaOfCall:(int)callId streamInfo:(const StreamInfo &)si {
    if (_calls.find(callId) == _calls.end()) return;
    [self.delegate callMediaActive:callId remoteEventPT:si.audTxEventPt localEventPT:si.audRxEventPt
                             codec:[NSString stringWithUTF8String:si.codecName.c_str()] ?: @""];
}

/// Hangs up every live call and tells the delegate each one ended, so no call is dropped silently.
- (void)endAllCallsWithReason:(NSString *)reason {
    std::map<int, std::unique_ptr<BridgeCall>> calls;
    calls.swap(_calls);                          // callbacks fired by hangup find nothing: we report once, below
    for (auto &entry : calls) {
        bool alreadyEnded = false;
        try { alreadyEnded = entry.second->getInfo().state == PJSIP_INV_STATE_DISCONNECTED; } catch (...) {}
        if (!alreadyEnded) {
            try { CallOpParam prm; prm.statusCode = PJSIP_SC_DECLINE; entry.second->hangup(prm); } catch (...) {}
            [self.delegate callStateChanged:entry.first state:@"ended" statusCode:487 reason:reason];
        }
    }
}

- (void)shutdown {
    [_timer invalidate]; _timer = nil;
    [self endAllCallsWithReason:@"Engine shut down"]; _acc.reset();
    if (_ep) { try { _ep->libDestroy(); } catch (...) {} _ep.reset(); }
}
@end
