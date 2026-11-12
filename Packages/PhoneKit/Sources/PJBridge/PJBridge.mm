#import "PJBridge.h"
#include <pjsua2.hpp>
#include <map>
#include <memory>
#include <string>

using namespace pj;

@interface PJBridge ()
- (void)handleRegCode:(int)code reason:(const std::string &)reason;
- (void)handleIncoming:(int)callId;
- (void)handleCallState:(int)callId;
- (void)applyMuteToCapture;
- (void)endAllCallsWithReason:(NSString *)reason;
@end

class BridgeAccount : public Account {
public:
    explicit BridgeAccount(PJBridge *owner) : owner_(owner) {}
    void onRegState(OnRegStateParam &prm) override { [owner_ handleRegCode:prm.code reason:prm.reason]; }
    void onIncomingCall(OnIncomingCallParam &prm) override { [owner_ handleIncoming:prm.callId]; }
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
                }
            }
        } catch (Error &) {}
        [owner_ applyMuteToCapture];
    }
private:
    __unsafe_unretained PJBridge *owner_;
};

@implementation PJBridge {
    std::unique_ptr<Endpoint> _ep;
    std::unique_ptr<BridgeAccount> _acc;
    std::map<int, std::unique_ptr<BridgeCall>> _calls;
    NSTimer *_timer;
    std::string _host;
    BOOL _muted;
}

+ (NSString *)version { return [NSString stringWithUTF8String:pj_get_version()]; }

static NSError *PJError(const std::string &msg) {
    return [NSError errorWithDomain:@"PJBridge" code:1 userInfo:@{NSLocalizedDescriptionKey: @(msg.c_str())}];
}

- (void)dealloc { [self shutdown]; }

- (BOOL)startAndReturnError:(NSError **)error {
    if (_ep) return YES;
    try {
        _ep.reset(new Endpoint);
        _ep->libCreate();
        EpConfig cfg;
        cfg.uaConfig.threadCnt = 0;              // we pump events from the main thread
        cfg.uaConfig.mainThreadOnly = true;
        cfg.uaConfig.userAgent = "FritzPhone";
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
    try {
        [self endAllCallsWithReason:@"Account replaced"];   // calls reference the account: end them first
        _acc.reset();
        _host = host.UTF8String;
        AccountConfig ac;
        ac.idUri = "sip:" + std::string(user.UTF8String) + "@" + _host;
        ac.regConfig.registrarUri = "sip:" + _host;
        ac.regConfig.timeoutSec = 300;
        ac.regConfig.retryIntervalSec = 0;       // AppCore owns reconnect/backoff; no pjsua-internal retry
        ac.sipConfig.authCreds.push_back(AuthCredInfo("digest", "*", user.UTF8String, 0, password.UTF8String));
        _acc.reset(new BridgeAccount(self));
        _acc->create(ac);
        return YES;
    } catch (Error &e) {
        _acc.reset();
        if (error) *error = PJError(e.info());
        return NO;
    }
}

- (void)unregisterAccount {
    // Destroying the account unregisters it; callbacks from a dying account are ignored (_acc is null).
    [self endAllCallsWithReason:@"Account removed"];
    try { _acc.reset(); } catch (...) {}
}

- (nullable NSNumber *)dial:(NSString *)number error:(NSError **)error {
    if (!_acc) { if (error) *error = PJError("Not registered"); return nil; }
    NSString *clean = [[number stringByReplacingOccurrencesOfString:@" " withString:@""]
                       stringByReplacingOccurrencesOfString:@"#" withString:@"%23"];
    try {
        std::unique_ptr<BridgeCall> call(new BridgeCall(*_acc, PJSUA_INVALID_ID, self));
        CallOpParam prm(true);
        call->makeCall("sip:" + std::string(clean.UTF8String) + "@" + _host, prm);
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

- (void)handleIncoming:(int)callId {
    if (!_acc) return;
    try {
        std::unique_ptr<BridgeCall> call(new BridgeCall(*_acc, callId, self));
        NSString *remote = @(call->getInfo().remoteUri.c_str());
        try { CallOpParam ringing; ringing.statusCode = PJSIP_SC_RINGING; call->answer(ringing); } catch (...) {}
        _calls[callId] = std::move(call);
        [self.delegate incomingCall:callId from:remote];
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

- (void)sendDTMF:(NSString *)digits callId:(NSInteger)callId {
    auto it = _calls.find((int)callId); if (it == _calls.end()) return;
    try { it->second->dialDtmf(std::string(digits.UTF8String)); } catch (...) {}
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
