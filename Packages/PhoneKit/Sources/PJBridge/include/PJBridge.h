#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

@protocol PJBridgeDelegate <NSObject>
/// Only final results are reported (statusCode >= 200).
- (void)registrationChanged:(NSInteger)statusCode reason:(NSString *)reason;
/// `called`: best-effort raw URI/header of the own number that was called (P-Called-Party-ID, else To); may be empty.
- (void)incomingCall:(NSInteger)callId from:(NSString *)remote called:(NSString *)called;
/// state: "calling" | "ringing" | "connected" | "ended"
- (void)callStateChanged:(NSInteger)callId state:(NSString *)state statusCode:(NSInteger)code reason:(NSString *)reason;
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
- (void)sendDTMF:(NSString *)digits callId:(NSInteger)callId;
- (void)shutdown;
@end
NS_ASSUME_NONNULL_END
