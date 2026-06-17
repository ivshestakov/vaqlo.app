import Foundation

/// Общие константы для обмена состоянием между приложением и контролом
/// в Control Center. Файл компилируется в оба таргета.
enum VaqloShared {
    static let groupID = "group.com.vaqlo"
    static let controlKind = "com.vaqlo.recorder.record"
    static let isRecordingKey = "isRecording"
    static let requestedKey = "requestedRecording"
    static let startedAtKey = "recordingStartedAt"   // timeIntervalSince1970
    static let pendingKey = "pendingCount"
    static let toggleNotification = NSNotification.Name("com.vaqlo.recorder.toggle")

    static var defaults: UserDefaults? { UserDefaults(suiteName: groupID) }
}
