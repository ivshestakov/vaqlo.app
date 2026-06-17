import Foundation

/// Все данные приложения живут в Application Support.
enum Storage {
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vaqlo")
    }

    static var recordings: URL { root.appendingPathComponent("recordings") }
    static var models: URL { root.appendingPathComponent("models") }
    static var trashLog: URL { root.appendingPathComponent("trash.json") }

    static func prepare() {
        let fm = FileManager.default
        try? fm.createDirectory(at: recordings, withIntermediateDirectories: true)
        try? fm.createDirectory(at: models, withIntermediateDirectories: true)
        migrateLegacyRecordings()
    }

    /// Записи фазы 1 лежали в ~/VaqloRecordings — переносим их внутрь приложения.
    private static func migrateLegacyRecordings() {
        let fm = FileManager.default
        let legacy = fm.homeDirectoryForCurrentUser.appendingPathComponent("VaqloRecordings")
        guard fm.fileExists(atPath: legacy.path) else { return }
        let days = (try? fm.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil)) ?? []
        for day in days where day.hasDirectoryPath {
            let target = recordings.appendingPathComponent(day.lastPathComponent)
            if fm.fileExists(atPath: target.path) {
                // День уже есть — переносим сессии по одной.
                let sessions = (try? fm.contentsOfDirectory(at: day, includingPropertiesForKeys: nil)) ?? []
                for session in sessions {
                    try? fm.moveItem(at: session, to: target.appendingPathComponent(session.lastPathComponent))
                }
            } else {
                try? fm.moveItem(at: day, to: target)
            }
        }
        if ((try? fm.contentsOfDirectory(atPath: legacy.path)) ?? []).isEmpty {
            try? fm.removeItem(at: legacy)
        }
    }
}

enum SettingsKeys {
    static let scheduleMode = "scheduleMode"           // 0 выкл, 1 каждые N часов, 2 ежедневно
    static let scheduleIntervalHours = "scheduleIntervalHours"
    static let scheduleDailyMinutes = "scheduleDailyMinutes" // минуты от полуночи
    static let retentionDays = "retentionDays"         // сколько держать аудио в корзине
    static let exportFolder = "exportFolder"
    static let activeModel = "activeModel"
    static let hotKeyCode = "hotKeyCode"               // Carbon key code
    static let hotKeyModifiers = "hotKeyModifiers"     // Carbon modifiers
    static let idleEmoji = "idleEmoji"
    static let recordingEmoji = "recordingEmoji"
    static let language = "language"                   // "auto" | "ru" | "en"
    static let selfLabel = "selfLabel"                 // как подписывать реплики с микрофона
    static let activeSummaryModel = "activeSummaryModel"
    static let autoSummarize = "autoSummarize"         // саммари сразу после транскрибации
    static let meetingDetection = "meetingDetection"   // 0 выкл, 1 уведомлять, 2 автозапись
    static let meetingAutoStop = "meetingAutoStop"     // останавливать автозапись, когда микрофон освободился
    static let onboardingDone = "onboardingDone"
    static let appLanguage = "appLanguage"             // код языка интерфейса (uk/en/…)
    static let detectSpeakerNames = "detectSpeakerNames" // читать имена говорящих из Slack/Zoom
    static let appPolicies = "appPolicies"             // JSON [TriggerApp]: приложение → политика записи

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            scheduleMode: 0,
            scheduleIntervalHours: 4,
            scheduleDailyMinutes: 21 * 60,
            retentionDays: 7,
            activeModel: "large-v3-turbo-q5_0",
            hotKeyCode: kVK_ANSI_R_Code,
            hotKeyModifiers: Int(HotKey.cmdOption),
            idleEmoji: "😶",
            recordingEmoji: "🙂",
            language: "auto",
            selfLabel: "",
            activeSummaryModel: "qwen3-4b-instruct-q4",
            autoSummarize: false,
            meetingDetection: 1,
            meetingAutoStop: true,
            detectSpeakerNames: true,
        ])
    }
}
