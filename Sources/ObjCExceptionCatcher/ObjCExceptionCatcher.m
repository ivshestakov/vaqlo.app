#import "ObjCExceptionCatcher.h"

NSError * _Nullable VQCatchObjCException(void (NS_NOESCAPE ^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        NSString *reason = exception.reason ?: exception.name;
        return [NSError errorWithDomain:@"VaqloObjCException"
                                   code:1
                               userInfo:@{NSLocalizedDescriptionKey: reason}];
    }
}
