import AppKit
import CoreAudio
import Foundation

/// Определяет, что какое-то приложение использует микрофон (= скорее всего идёт звонок/встреча),
/// через Core Audio process-objects API. Не пишет звук сам — только наблюдает.
enum MeetingDetector {
    /// Человекочитаемые имена для частых «встречных» приложений.
    private static let knownNames: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams": "Microsoft Teams",
        "com.microsoft.teams2": "Microsoft Teams",
        "com.cisco.webexmeetingsapp": "Webex",
        "com.webex.meetingmanager": "Webex",
        "com.apple.FaceTime": "FaceTime",
        "com.skype.skype": "Skype",
        "com.hnc.Discord": "Discord",
        "com.google.Chrome": "Chrome",
        "com.apple.Safari": "Safari",
        "org.mozilla.firefox": "Firefox",
        "company.thebrowser.Browser": "Arc",
        "com.brave.Browser": "Brave",
    ]

    /// Bundle id самого Vaqlo — исключаем, мы сами открываем микрофон при записи.
    private static let ownBundleID = "com.vaqlo.recorder"

    struct ActiveMic {
        let bundleID: String
        var displayName: String {
            knownNames[bundleID]
                ?? NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName
                ?? bundleID
        }
    }

    /// Приложения, прямо сейчас использующие вход (микрофон), кроме нас самих.
    static func appsUsingMic() -> [ActiveMic] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var listAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &listAddress, 0, nil, &dataSize) == noErr else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var processIDs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &listAddress, 0, nil, &dataSize, &processIDs) == noErr else { return [] }

        var result: [ActiveMic] = []
        for processID in processIDs {
            guard isRunningInput(processID), let bundleID = bundleID(processID), bundleID != ownBundleID else { continue }
            result.append(ActiveMic(bundleID: bundleID))
        }
        return result
    }

    private static func isRunningInput(_ processID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(processID, &address, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }

    private static func bundleID(_ processID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfString: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &cfString) {
            AudioObjectGetPropertyData(processID, &address, 0, nil, &size, $0)
        }
        let value = cfString as String
        guard status == noErr, !value.isEmpty else { return nil }
        return value
    }
}
