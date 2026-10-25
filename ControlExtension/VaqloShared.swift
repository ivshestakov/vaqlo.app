import Foundation

/// Общие константы для обмена состоянием между приложением и контролом
/// в Control Center. Файл компилируется в оба таргета.
enum VaqloShared {
    /// TEAMID-префикс: «group.*» без provisioning profile macOS молча игнорирует
    /// (контейнер не общий, виджет видел устаревшее состояние).
    static let groupID = "975ZZPJQNB.com.vaqlo"
    static let controlKind = "com.vaqlo.recorder.record"
    static let isRecordingKey = "isRecording"
    static let requestedKey = "requestedRecording"
    /// Запрос от контрола подтверждается свежей меткой времени и одноразовым id в общем
    /// контейнере: писать туда может только приложение нашей команды, а distributed-
    /// нотификацию — кто угодно. Без этой проверки любой процесс включал запись.
    static let requestTimeKey = "requestedAt"          // timeIntervalSince1970
    static let requestIDKey = "requestID"
    static let requestTTL: TimeInterval = 10
    static let startedAtKey = "recordingStartedAt"   // timeIntervalSince1970
    static let pendingKey = "pendingCount"
    static let toggleNotification = NSNotification.Name("com.vaqlo.recorder.toggle")

    static var defaults: UserDefaults? { UserDefaults(suiteName: groupID) }
}
