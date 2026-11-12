// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Aarne Aarebye

#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

/// Wire method for one sendDTMF call.
typedef NS_ENUM(NSInteger, PJDTMFMethod) {
    PJDTMFMethodRFC2833 = 0,   ///< Call::dialDtmf (RTP telephone-event)
    PJDTMFMethodSIPInfo = 1,   ///< Call::sendDtmf with PJSUA_DTMF_METHOD_SIP_INFO
    PJDTMFMethodInband = 2,    ///< tone generator mixed into the call's outgoing audio
};

/// Error domain for sendDTMF failures: code = pj_status_t, description = PJSIP reason (never the digits).
extern NSString *const PJBridgeErrorDomain;

@protocol PJBridgeDelegate <NSObject>
/// Only final results are reported (statusCode >= 200).
- (void)registrationChanged:(NSInteger)statusCode reason:(NSString *)reason;
/// `called`: best-effort raw URI/header of the own number that was called (P-Called-Party-ID, else To); may be empty.
- (void)incomingCall:(NSInteger)callId from:(NSString *)remote called:(NSString *)called;
/// state: "calling" | "ringing" | "connected" | "ended"
- (void)callStateChanged:(NSInteger)callId state:(NSString *)state statusCode:(NSInteger)code reason:(NSString *)reason;
/// Audio became active. Event payload types are -1 when telephone-event was not negotiated
/// (remote = what we send with, from the remote SDP; local = what we receive on, from our SDP).
- (void)callMediaActive:(NSInteger)callId remoteEventPT:(NSInteger)remotePT localEventPT:(NSInteger)localPT codec:(NSString *)codec;
@end

/// Thin ObjC wrapper over pjsua2. Call every method on the main thread; delegate callbacks arrive on the main thread.
@interface PJBridge : NSObject
@property (nonatomic, weak, nullable) id<PJBridgeDelegate> delegate;
+ (NSString *)version;
- (BOOL)startAndReturnError:(NSError **)error;
- (BOOL)registerAccountWithHost:(NSString *)host user:(NSString *)user password:(NSString *)password error:(NSError **)error;
/// Tears the account down (sends an unregister); a later registerAccount creates a fresh one.
- (void)unregisterAccount;
- (nullable NSNumber *)dial:(NSString *)number error:(NSError **)error;
- (void)answer:(NSInteger)callId;
- (void)hangup:(NSInteger)callId;
- (void)setMuted:(BOOL)muted;
/// Sends with exactly one method. On failure `error` carries the PJSIP status (code) and reason; nothing is swallowed.
- (BOOL)sendDTMF:(NSString *)digits callId:(NSInteger)callId method:(PJDTMFMethod)method error:(NSError **)error;
- (void)shutdown;
@end
NS_ASSUME_NONNULL_END
