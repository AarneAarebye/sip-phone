// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Aarne Aarebye

#import "PJBridge.h"
#include <pjsua2.hpp>
#include <pjsua-lib/pjsua_internal.h>   // pjsua_var.calls[id].inv: active SDP and pjsip_inv_terminate
#include <os/log.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netdb.h>
#include <arpa/inet.h>
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
- (void)callMediaStateChanged:(int)callId anyActive:(BOOL)active statuses:(const std::string &)statuses;
@end

// Logging: subsystem com.aarneaarebye.sipphone; category "call" (lifecycle, ids only) and "media" (addresses,
// ports, payload types and RTP counters). Never numbers, URIs, credentials or keys. Public IP addresses are masked.
static os_log_t CallLog() { static os_log_t l = os_log_create("com.aarneaarebye.sipphone", "call"); return l; }
static os_log_t MediaLog() { static os_log_t l = os_log_create("com.aarneaarebye.sipphone", "media"); return l; }
static os_log_t SipLog() { static os_log_t l = os_log_create("com.aarneaarebye.sipphone", "sip"); return l; }

static const char *InvStateName(int s) {
    switch (s) {
        case PJSIP_INV_STATE_NULL: return "NULL";
        case PJSIP_INV_STATE_CALLING: return "CALLING";
        case PJSIP_INV_STATE_INCOMING: return "INCOMING";
        case PJSIP_INV_STATE_EARLY: return "EARLY";
        case PJSIP_INV_STATE_CONNECTING: return "CONNECTING";
        case PJSIP_INV_STATE_CONFIRMED: return "CONFIRMED";
        case PJSIP_INV_STATE_DISCONNECTED: return "DISCONNECTED";
        default: return "?";
    }
}

static const char *MediaStatusName(pjsua_call_media_status s) {
    switch (s) {
        case PJSUA_CALL_MEDIA_NONE: return "none";
        case PJSUA_CALL_MEDIA_ACTIVE: return "active";
        case PJSUA_CALL_MEDIA_LOCAL_HOLD: return "local-hold";
        case PJSUA_CALL_MEDIA_REMOTE_HOLD: return "remote-hold";
        case PJSUA_CALL_MEDIA_ERROR: return "error";
        default: return "?";
    }
}

/// The address itself for private, loopback, link-local, CGNAT and unspecified addresses; "<public>" otherwise.
static std::string SafeIP(const std::string &ip) {
    if (ip.empty()) return "(none)";
    in_addr a4;
    if (inet_pton(AF_INET, ip.c_str(), &a4) == 1) {
        uint32_t v = ntohl(a4.s_addr);
        bool ok = (v >> 24) == 10 || (v >> 20) == 0xAC1 || (v >> 16) == 0xC0A8 || (v >> 24) == 127
               || (v >> 16) == 0xA9FE || (v >> 22) == (0x64400000u >> 22) || v == 0;
        return ok ? ip : "<public>";
    }
    in6_addr a6;
    if (inet_pton(AF_INET6, ip.c_str(), &a6) == 1) {
        bool ok = IN6_IS_ADDR_LINKLOCAL(&a6) || IN6_IS_ADDR_LOOPBACK(&a6) || IN6_IS_ADDR_UNSPECIFIED(&a6)
               || (a6.s6_addr[0] & 0xFE) == 0xFC;
        return ok ? ip : "<public-v6>";
    }
    return "<name>";   // a host name is never printed
}

/// "a.b.c.d:port" or "[v6]:port" with the address passed through SafeIP.
static std::string SafeHostPort(const std::string &hp) {
    if (hp.empty()) return "(none)";
    std::string host = hp, port;
    if (hp[0] == '[') {
        size_t e = hp.find(']');
        if (e != std::string::npos) { host = hp.substr(1, e - 1); if (e + 2 <= hp.size()) port = hp.substr(e + 2); }
    } else {
        size_t c = hp.rfind(':');
        if (c != std::string::npos && hp.find(':') == c) { host = hp.substr(0, c); port = hp.substr(c + 1); }
    }
    return SafeIP(host) + (port.empty() ? "" : ":" + port);
}

static std::string PjStr(const pj_str_t &s) { return s.slen > 0 ? std::string(s.ptr, (size_t)s.slen) : std::string(); }

/// The Mac's IPv4 interface addresses (no loopback), e.g. "en0=192.168.179.23 utun4=192.168.65.204".
static std::string InterfaceSummary() {
    struct ifaddrs *head = nullptr;
    if (getifaddrs(&head) != 0) return "(getifaddrs failed)";
    std::string out;
    for (struct ifaddrs *i = head; i; i = i->ifa_next) {
        if (!i->ifa_addr || i->ifa_addr->sa_family != AF_INET || (i->ifa_flags & IFF_LOOPBACK)) continue;
        char host[NI_MAXHOST];
        if (getnameinfo(i->ifa_addr, i->ifa_addr->sa_len, host, sizeof host, nullptr, 0, NI_NUMERICHOST) != 0) continue;
        if (!out.empty()) out += " ";
        out += std::string(i->ifa_name) + "=" + SafeIP(host) + ((i->ifa_flags & IFF_UP) ? "" : "(down)");
    }
    freeifaddrs(head);
    return out.empty() ? "(none)" : out;
}

/// Connection address, port, direction and payload types of each m= line; nothing else of the SDP.
static std::string SdpSummary(const pjmedia_sdp_session *sdp) {
    if (!sdp) return "(none)";
    static const char *dirs[] = {"sendrecv", "sendonly", "recvonly", "inactive"};
    std::string sessConn = sdp->conn ? PjStr(sdp->conn->addr) : "";
    std::string sessDir;
    for (const char *d : dirs) if (pjmedia_sdp_attr_find2(sdp->attr_count, sdp->attr, d, nullptr)) sessDir = d;
    std::string out;
    for (unsigned i = 0; i < sdp->media_count; i++) {
        const pjmedia_sdp_media *m = sdp->media[i];
        std::string dir = sessDir.empty() ? "sendrecv(implicit)" : sessDir;
        for (const char *d : dirs) if (pjmedia_sdp_media_find_attr2(m, d, nullptr)) dir = d;
        std::string pts;
        for (unsigned j = 0; j < m->desc.fmt_count; j++) { if (j) pts += ","; pts += PjStr(m->desc.fmt[j]); }
        if (!out.empty()) out += " | ";
        out += PjStr(m->desc.media) + " c=" + SafeIP(m->conn ? PjStr(m->conn->addr) : sessConn)
             + " port=" + std::to_string(m->desc.port) + " dir=" + dir + " pt=" + pts;
    }
    return out.empty() ? "(no m= line)" : out;
}

/// Active local and remote SDP of a call (from the INVITE session's negotiator), or "(none)".
static void ActiveSdp(int callId, std::string &local, std::string &remote) {
    local = remote = "(none)";
    if (callId < 0 || callId >= (int)PJSUA_MAX_CALLS) return;
    pjsip_inv_session *inv = pjsua_var.calls[callId].inv;
    if (!inv || !inv->neg) return;
    const pjmedia_sdp_session *l = nullptr, *r = nullptr;
    if (pjmedia_sdp_neg_get_active_local(inv->neg, &l) == PJ_SUCCESS) local = SdpSummary(l);
    if (pjmedia_sdp_neg_get_active_remote(inv->neg, &r) == PJ_SUCCESS) remote = SdpSummary(r);
}

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
    void onRegState(OnRegStateParam &prm) override {
        // A 2xx with expiration 0 answers an un-REGISTER (sent by handleIpChange before it re-registers with the
        // new contact): not a registration result. Explicit unregisters destroy the account, which is ignored anyway.
        if (prm.code / 100 == 2 && prm.expiration == 0) return;
        [owner_ handleRegCode:prm.code reason:prm.reason];
    }
    void onIncomingCall(OnIncomingCallParam &prm) override { [owner_ handleIncoming:prm.callId wholeMsg:prm.rdata.wholeMsg]; }
private:
    __unsafe_unretained PJBridge *owner_;   // the bridge owns (and outlives) its account
};

class BridgeCall : public Call {
public:
    BridgeCall(Account &acc, int callId, PJBridge *owner) : Call(acc, callId), owner_(owner) {}
    void onCallState(OnCallStateParam &) override { [owner_ handleCallState:getId()]; }
    void onCallMediaState(OnCallMediaStateParam &) override {
        bool anyActive = false;
        std::string statuses;
        try {
            CallInfo ci = getInfo();
            for (unsigned i = 0; i < ci.media.size(); i++) {
                if (ci.media[i].type == PJMEDIA_TYPE_AUDIO) {
                    if (!statuses.empty()) statuses += ",";
                    statuses += std::to_string(i) + ":" + MediaStatusName(ci.media[i].status);
                }
                if (ci.media[i].type == PJMEDIA_TYPE_AUDIO && ci.media[i].status == PJSUA_CALL_MEDIA_ACTIVE) {
                    anyActive = true;
                    AudioMedia *aud = static_cast<AudioMedia *>(getMedia(i));
                    AudDevManager &mgr = Endpoint::instance().audDevManager();
                    aud->startTransmit(mgr.getPlaybackDevMedia());
                    mgr.getCaptureDevMedia().startTransmit(*aud);
                    if (toneGen_) { try { toneGen_->startTransmit(*aud); } catch (Error &) {} }   // re-INVITE: new port
                    try { [owner_ reportMediaOfCall:getId() streamInfo:getStreamInfo(i)]; } catch (Error &) {}
                }
            }
        } catch (Error &e) { statuses += " (getInfo failed: " + e.reason + ")"; }
        [owner_ applyMuteToCapture];
        [owner_ callMediaStateChanged:getId() anyActive:anyActive statuses:statuses];
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
    /// Samples RTP counters every 5 s while a call has active media; invalidated when no call is left.
    NSTimer *_mediaTimer;
    /// Last counters line per call: PJSIP drops the stream before reporting DISCONNECTED.
    std::map<int, std::string> _lastStat;
    std::string _host, _user, _password, _bindAddress;
    PJMediaAddressMode _mediaMode;
    int _sipTransportId;
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
        _sipTransportId = _ep->transportCreate(PJSIP_TRANSPORT_UDP, tcfg);
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
    return [self registerAccountWithHost:host user:user password:password mediaMode:PJMediaAddressModeAutomatic bindAddress:nil error:error];
}

- (BOOL)registerAccountWithHost:(NSString *)host user:(NSString *)user password:(NSString *)password
                      mediaMode:(PJMediaAddressMode)mediaMode bindAddress:(NSString *)bindAddress error:(NSError **)error {
    if (!_ep) { if (error) *error = PJError("Engine not started"); return NO; }
    const char *h = host.UTF8String, *u = user.UTF8String, *p = password.UTF8String;
    if (!h || !u || !p) { if (error) *error = PJError("Invalid account data"); return NO; }
    std::string bind = (mediaMode == PJMediaAddressModeTunnelInterface && bindAddress.UTF8String) ? bindAddress.UTF8String : "";
    if (mediaMode == PJMediaAddressModeTunnelInterface && bind.empty()) mediaMode = PJMediaAddressModeAutomatic;
    bool sameCredentials = _acc && _host == h && _user == u && _password == p;
    bool sameMedia = _mediaMode == mediaMode && _bindAddress == bind;
    if (sameCredentials && !sameMedia && !_calls.empty()) {
        os_log(SipLog(), "media address mode change waits until no call is live");
        sameMedia = true;   // keep the account (and the live call); the next registration applies it
    }
    // Same account: refresh the registration in place. Live calls reference the account and must survive
    // network changes, wake and Settings saves, so only a real account change ends them.
    if (sameCredentials && sameMedia) {
        try { _acc->setRegistration(true); return YES; }
        catch (Error &e) {
            // A REGISTER is already in flight (e.g. the one handleIpChange sends): its result arrives via onRegState.
            if (e.status == PJSIP_EBUSY) return YES;
            /* otherwise fall back to recreating the account */
        }
    }
    try {
        [self endAllCallsWithReason:@"Account replaced"];   // calls reference the account: end them first
        _acc.reset();
        _host = h; _user = u; _password = p;
        _mediaMode = mediaMode; _bindAddress = bind;
        AccountConfig ac;
        ac.idUri = "sip:" + _user + "@" + _host;
        ac.regConfig.registrarUri = "sip:" + _host;
        ac.regConfig.timeoutSec = 300;
        ac.regConfig.retryIntervalSec = 0;       // AppCore owns reconnect/backoff; no pjsua-internal retry
        ac.sipConfig.authCreds.push_back(AuthCredInfo("digest", "*", _user, 0, _password));
        switch (_mediaMode) {
            case PJMediaAddressModeNatRewrite:
                // SDP c= takes the address the FRITZ!Box saw in our REGISTER (Via received=), which with the
                // tunnel up is the tunnel IP. Contact/Via rewrite (pjsua defaults) stay on: they learn that address.
                ac.natConfig.sdpNatRewriteUse = 1;
                ac.natConfig.contactRewriteUse = 1;
                ac.natConfig.viaRewriteUse = 1;
                break;
            case PJMediaAddressModeTunnelInterface:
                // The RTP socket binds to the tunnel IPv4 and the SDP advertises it.
                ac.mediaConfig.transportConfig.boundAddress = _bindAddress;
                ac.mediaConfig.transportConfig.publicAddress = _bindAddress;
                break;
            default: break;
        }
        os_log(SipLog(), "account created: media address mode %{public}s%{public}s%{public}s",
               _mediaMode == PJMediaAddressModeNatRewrite ? "nat-rewrite" : _mediaMode == PJMediaAddressModeTunnelInterface ? "tunnel-interface" : "automatic",
               _bindAddress.empty() ? "" : " bound to ", SafeIP(_bindAddress).c_str());
        _acc.reset(new BridgeAccount(self));
        _acc->create(ac);
        return YES;
    } catch (Error &e) {
        _acc.reset();
        if (error) *error = PJError(e.info());
        return NO;
    }
}

/// Stores a new call under its pjsua id. A stale entry with the same id (its deferred erase has not run yet)
/// must not be destroyed: pjsua2's Call destructor would clear the user data of, and hang up, the NEW call
/// that now owns the id. It is released (leaked) instead and logged; pjsua's round-robin ids make this rare.
static void StoreCall(std::map<int, std::unique_ptr<BridgeCall>> &calls, int id, std::unique_ptr<BridgeCall> call) {
    auto old = calls.find(id);
    if (old != calls.end()) {
        os_log_error(CallLog(), "call id %d reused while a stale entry exists: stale entry released", id);
        (void)old->second.release();
        calls.erase(old);
    }
    calls[id] = std::move(call);
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
        StoreCall(_calls, id, std::move(call));
        os_log(CallLog(), "bridge dial: id %d", id);
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
        StoreCall(_calls, callId, std::move(call));
        os_log(CallLog(), "bridge incoming: id %d", callId);
        [self.delegate incomingCall:callId from:remote called:called];
    } catch (...) { os_log_error(CallLog(), "bridge incoming: id %d could not be set up", callId); }
}

- (void)handleCallState:(int)callId {
    auto it = _calls.find(callId);
    if (it == _calls.end()) {
        os_log(CallLog(), "onCallState id %d: not in calls map, not reported", callId);
        return;
    }
    CallInfo ci;
    try { ci = it->second->getInfo(); }
    catch (Error &e) {
        // Without the state the end cannot be told apart; AppCore's reconcile (isCallActive) recovers.
        os_log_error(CallLog(), "onCallState id %d: getInfo failed [status %d], not reported", callId, (int)e.status);
        return;
    }
    catch (...) { os_log_error(CallLog(), "onCallState id %d: getInfo failed, not reported", callId); return; }
    os_log(CallLog(), "onCallState id %d state %{public}s code %d reason %{public}s", callId, InvStateName(ci.state),
           (int)ci.lastStatusCode, ci.lastReason.c_str());
    NSString *state = nil;
    switch (ci.state) {
        case PJSIP_INV_STATE_CALLING: state = @"calling"; break;
        case PJSIP_INV_STATE_EARLY: state = @"ringing"; break;
        case PJSIP_INV_STATE_CONFIRMED: state = @"connected"; break;
        case PJSIP_INV_STATE_DISCONNECTED: state = @"ended"; break;
        default: break;
    }
    if (!state) return;   // NULL, INCOMING, CONNECTING: not reported (logged above)
    if (ci.state == PJSIP_INV_STATE_DISCONNECTED) [self logFinalMediaOfCall:callId];
    [self.delegate callStateChanged:callId state:state statusCode:ci.lastStatusCode reason:@(ci.lastReason.c_str()) ?: @""];
    if (ci.state == PJSIP_INV_STATE_DISCONNECTED) [self scheduleErase:callId];
}

/// Never deletes a Call inside its own callback, and never an entry that a new call with the same id replaced.
- (void)scheduleErase:(int)callId {
    auto it = _calls.find(callId);
    if (it == _calls.end()) return;
    BridgeCall *ptr = it->second.get();
    __weak PJBridge *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        PJBridge *s = weakSelf; if (!s) return;
        auto f = s->_calls.find(callId);
        if (f != s->_calls.end() && f->second.get() == ptr) {
            s->_calls.erase(f);
            s->_lastStat.erase(callId);
            os_log(CallLog(), "call id %d erased", callId);
        } else {
            os_log(CallLog(), "call id %d erase skipped: already gone or id reused", callId);
        }
        [s stopMediaTimerIfIdle];
    });
}

- (BOOL)isCallActive:(NSInteger)callId {
    auto it = _calls.find((int)callId);
    if (it == _calls.end()) return NO;
    try { return it->second->getInfo().state != PJSIP_INV_STATE_DISCONNECTED; } catch (...) { return NO; }
}

- (void)forceEndCall:(NSInteger)cid {
    int callId = (int)cid;
    auto it = _calls.find(callId);
    if (it == _calls.end()) { os_log(CallLog(), "forceEnd id %d: not in calls map", callId); return; }
    BridgeCall *call = it->second.get();
    int st = -1;
    try { st = call->getInfo().state; } catch (...) {}
    os_log(CallLog(), "forceEnd id %d: state %{public}s", callId, st < 0 ? "unknown" : InvStateName(st));
    if (st != PJSIP_INV_STATE_DISCONNECTED) {
        pjsip_inv_session *inv = (callId >= 0 && callId < (int)PJSUA_MAX_CALLS) ? pjsua_var.calls[callId].inv : nullptr;
        if (inv && pjsua_call_get_user_data(callId) == call) {
            // Ends the session now (DISCONNECTED is reported through onCallState) instead of waiting for a BYE
            // response or Timer F.
            pj_status_t status = pjsip_inv_terminate(inv, PJSIP_SC_REQUEST_TIMEOUT, PJ_TRUE);
            os_log(CallLog(), "forceEnd id %d: pjsip_inv_terminate status %d", callId, (int)status);
        } else {
            try { CallOpParam prm; prm.statusCode = PJSIP_SC_DECLINE; call->hangup(prm); } catch (...) {}
            os_log(CallLog(), "forceEnd id %d: no INVITE session, hangup sent", callId);
        }
    }
    [self scheduleErase:callId];   // no-op if the DISCONNECTED callback already scheduled it
}

- (void)handleRegCode:(int)code reason:(const std::string &)reason {
    if (!_acc || code < 200) return;             // only final results
    [self.delegate registrationChanged:code reason:@(reason.c_str())];
}

- (void)answer:(NSInteger)callId {
    auto it = _calls.find((int)callId);
    os_log(CallLog(), "answer id %ld: %{public}s", (long)callId, it == _calls.end() ? "not in calls map" : "known");
    if (it == _calls.end()) return;
    try { CallOpParam prm; prm.statusCode = PJSIP_SC_OK; it->second->answer(prm); }
    catch (Error &e) { os_log_error(CallLog(), "answer id %ld failed [status %d]", (long)callId, (int)e.status); }
    catch (...) {}
}

- (void)hangup:(NSInteger)callId {
    auto it = _calls.find((int)callId);
    int st = -1;
    if (it != _calls.end()) { try { st = it->second->getInfo().state; } catch (...) {} }
    os_log(CallLog(), "hangup id %ld: %{public}s, state %{public}s", (long)callId,
           it == _calls.end() ? "not in calls map" : "known", st < 0 ? "unknown" : InvStateName(st));
    if (it == _calls.end()) return;
    [self logMediaOfCall:(int)callId full:NO why:"before hangup"];   // the stream is gone right after hangup
    // 603 Decline for an unanswered incoming call; pjsua sends CANCEL/BYE as appropriate otherwise
    try { CallOpParam prm; prm.statusCode = PJSIP_SC_DECLINE; it->second->hangup(prm); }
    catch (Error &e) { os_log_error(CallLog(), "hangup id %ld failed [status %d]", (long)callId, (int)e.status); }
    catch (...) {}
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

- (void)callMediaStateChanged:(int)callId anyActive:(BOOL)active statuses:(const std::string &)statuses {
    os_log(CallLog(), "onCallMediaState id %d audio %{public}s", callId, statuses.empty() ? "(no audio media)" : statuses.c_str());
    if (_calls.find(callId) == _calls.end()) return;
    if (active) {
        [self logMediaOfCall:callId full:YES why:"media active"];
        if (!_mediaTimer) {
            __weak PJBridge *weakSelf = self;
            _mediaTimer = [NSTimer timerWithTimeInterval:5 repeats:YES block:^(NSTimer *) {
                PJBridge *s = weakSelf; if (s) [s sampleMedia];
            }];
            [[NSRunLoop mainRunLoop] addTimer:_mediaTimer forMode:NSRunLoopCommonModes];
        }
    } else {
        [self logMediaOfCall:callId full:NO why:"media not active"];
    }
}

- (void)sampleMedia {
    if (!_ep) { [self stopMediaTimerIfIdle]; return; }
    for (auto &entry : _calls) [self logMediaOfCall:entry.first full:NO why:"5 s sample"];
    [self stopMediaTimerIfIdle];
}

- (void)stopMediaTimerIfIdle {
    if (_calls.empty() || !_ep) { [_mediaTimer invalidate]; _mediaTimer = nil; }
}

/// RTP/RTCP counters (and with `full` the negotiated addresses, SDP lines, SIP transport and interfaces)
/// of every audio stream of the call. Cheap: a few pjsua getters, no I/O beyond getifaddrs when `full`.
- (void)logMediaOfCall:(int)callId full:(BOOL)full why:(const char *)why {
    auto it = _calls.find(callId);
    if (it == _calls.end() || !_ep) return;
    BridgeCall *call = it->second.get();
    CallInfo ci;
    try { ci = call->getInfo(); } catch (...) { return; }
    for (unsigned i = 0; i < ci.media.size(); i++) {
        if (ci.media[i].type != PJMEDIA_TYPE_AUDIO) continue;
        std::string local = "(none)", src = "(none)", remote = "(none)", remoteRtcp = "(none)", codec;
        try {
            MediaTransportInfo ti = call->getMedTransportInfo(i);
            local = SafeHostPort(ti.localRtpName); src = SafeHostPort(ti.srcRtpName);
        } catch (...) {}
        bool haveStream = false;
        try {
            StreamInfo si = call->getStreamInfo(i);
            remote = SafeHostPort(si.remoteRtpAddress); remoteRtcp = SafeHostPort(si.remoteRtcpAddress);
            codec = si.codecName + "/" + std::to_string(si.codecClockRate) + " txPt " + std::to_string(si.txPt)
                  + " rxPt " + std::to_string(si.rxPt) + " dir " + std::to_string((int)si.dir);
            haveStream = true;
        } catch (...) {}
        std::string stat;
        try {
            StreamStat ss = call->getStreamStat(i);
            const RtcpStreamStat &tx = ss.rtcp.txStat, &rx = ss.rtcp.rxStat;
            pj_time_val now; pj_gettimeofday(&now);
            std::string lastRx = rx.update.sec > 0 ? std::to_string(now.sec - rx.update.sec) + " s ago" : "never";
            stat = "tx " + std::to_string(tx.pkt) + " pkts/" + std::to_string(tx.bytes) + " B, rx "
                 + std::to_string(rx.pkt) + " pkts/" + std::to_string(rx.bytes) + " B loss " + std::to_string(rx.loss)
                 + " discard " + std::to_string(rx.discard) + " jitter " + std::to_string(rx.jitterUsec.last / 1000)
                 + " ms (mean " + std::to_string(rx.jitterUsec.mean / 1000) + ") last rx " + lastRx
                 + ", rtt " + std::to_string(ss.rtcp.rttUsec.last / 1000) + " ms";
            _lastStat[callId] = stat;
        } catch (...) { stat = "(no stream)"; }
        os_log(MediaLog(), "call id %d media %u [%{public}s] %{public}s: %{public}s; local RTP %{public}s, remote RTP %{public}s, last RTP source %{public}s",
               callId, i, why, MediaStatusName(ci.media[i].status), stat.c_str(), local.c_str(), remote.c_str(), src.c_str());
        if (full && haveStream) {
            os_log(MediaLog(), "call id %d media %u negotiated: %{public}s, remote RTCP %{public}s", callId, i, codec.c_str(), remoteRtcp.c_str());
        }
    }
    if (full) {
        std::string l, r;
        ActiveSdp(callId, l, r);
        std::string sipLocal = "(unknown)";
        try { sipLocal = SafeHostPort(_ep->transportGetInfo(_sipTransportId).localName); } catch (...) {}
        os_log(MediaLog(), "call id %d local SDP: %{public}s", callId, l.c_str());
        os_log(MediaLog(), "call id %d remote SDP: %{public}s", callId, r.c_str());
        os_log(MediaLog(), "call id %d SIP transport %{public}s, media address mode %{public}s; interfaces %{public}s", callId,
               sipLocal.c_str(),
               _mediaMode == PJMediaAddressModeNatRewrite ? "nat-rewrite" : _mediaMode == PJMediaAddressModeTunnelInterface ? "tunnel-interface" : "automatic",
               InterfaceSummary().c_str());
    }
}

/// At DISCONNECTED the stream is already gone: log the last sample taken while it was alive.
- (void)logFinalMediaOfCall:(int)callId {
    auto s = _lastStat.find(callId);
    os_log(MediaLog(), "call id %d final (last sample): %{public}s; interfaces %{public}s", callId,
           s == _lastStat.end() ? "(no RTP sample: media never became active)" : s->second.c_str(), InterfaceSummary().c_str());
}

- (void)reportMediaOfCall:(int)callId streamInfo:(const StreamInfo &)si {
    if (_calls.find(callId) == _calls.end()) return;
    [self.delegate callMediaActive:callId remoteEventPT:si.audTxEventPt localEventPT:si.audRxEventPt
                             codec:[NSString stringWithUTF8String:si.codecName.c_str()] ?: @""];
}

/// Hangs up every live call and tells the delegate each one ended, so no call is dropped silently.
- (void)endAllCallsWithReason:(NSString *)reason {
    if (!_calls.empty()) os_log(CallLog(), "endAllCalls (%{public}@): %lu call(s)", reason, (unsigned long)_calls.size());
    std::map<int, std::unique_ptr<BridgeCall>> calls;
    calls.swap(_calls);                          // callbacks fired by hangup find nothing: we report once, below
    for (auto &entry : calls) {
        bool alreadyEnded = false;
        try { alreadyEnded = entry.second->getInfo().state == PJSIP_INV_STATE_DISCONNECTED; } catch (...) {}
        if (!alreadyEnded) {
            try { CallOpParam prm; prm.statusCode = PJSIP_SC_DECLINE; entry.second->hangup(prm); } catch (...) {}
        }
        // Reported for every call, also one already DISCONNECTED: its own report may have been lost (getInfo
        // failure in handleCallState); AppCore ignores a second end of an ended call.
        os_log(CallLog(), "endAllCalls: id %d reported ended (was %{public}s)", entry.first, alreadyEnded ? "disconnected" : "live");
        [self.delegate callStateChanged:entry.first state:@"ended" statusCode:487 reason:reason];
    }
    _lastStat.clear();
    [self stopMediaTimerIfIdle];
}

- (void)handleIpChange {
    if (!_ep) return;
    static os_log_t log = os_log_create("com.aarneaarebye.sipphone", "sip");
    if (!_calls.empty()) os_log(log, "network change with %lu call(s) in the bridge", (unsigned long)_calls.size());
    try {
        IpChangeParam prm;
        prm.restartListener = true;
        prm.restartLisDelay = PJSUA_TRANSPORT_RESTART_DELAY_TIME;   // 10 ms
        _ep->handleIpChange(prm);
        os_log(log, "network change: SIP transport restarted");
    } catch (Error &e) {
        os_log_error(log, "network change: handleIpChange failed [status %d]", (int)e.status);
    }
}

- (void)shutdown {
    [_timer invalidate]; _timer = nil;
    [_mediaTimer invalidate]; _mediaTimer = nil;
    [self endAllCallsWithReason:@"Engine shut down"]; _acc.reset();
    if (_ep) { try { _ep->libDestroy(); } catch (...) {} _ep.reset(); }
}
@end
