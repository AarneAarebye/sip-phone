#import "PJBridge.h"
#include <pjsua2.hpp>
@implementation PJBridge
+ (NSString *)version { return [NSString stringWithUTF8String:pj_get_version()]; }
@end
