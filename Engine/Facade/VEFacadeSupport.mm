// VEFacadeSupport: see VEFacadeSupport+Internal.h.

#import "VEFacadeSupport+Internal.h"

[[noreturn]] void veMainThreadViolation(const char *function) {
    [NSException raise:NSInternalInconsistencyException
                format:@"must be used on the main thread (%s called on %@)", function, NSThread.currentThread];
    __builtin_unreachable();
}
