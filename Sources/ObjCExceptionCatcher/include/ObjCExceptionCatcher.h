#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Выполняет блок, ловя Objective-C NSException — Swift их поймать не может,
/// а AVFAudio бросает их при гонках со сменой аудио-устройства.
/// Возвращает nil при успехе, иначе NSError с текстом исключения.
FOUNDATION_EXPORT NSError * _Nullable VQCatchObjCException(void (NS_NOESCAPE ^block)(void));

NS_ASSUME_NONNULL_END
