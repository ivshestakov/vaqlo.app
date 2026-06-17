import AppKit
import Foundation

/// Что делать, когда приложение начинает использовать микрофон.
enum AppPolicy: String, Codable, CaseIterable, Identifiable {
    case auto    // записывать автоматически
    case ask     // спрашивать каждый раз
    case never   // игнорировать (диктовщики, голосовые ассистенты)
    var id: String { rawValue }
}

/// Приложение-триггер с выбранной политикой.
struct TriggerApp: Codable, Identifiable {
    let bundleID: String
    var name: String
    var policy: AppPolicy
    var id: String { bundleID }
}

/// Персистентные правила «приложение → политика записи». Хранятся в UserDefaults (JSON).
enum MeetingPolicies {
    static func all() -> [TriggerApp] {
        guard let data = UserDefaults.standard.data(forKey: SettingsKeys.appPolicies) else { return [] }
        return ((try? JSONDecoder().decode([TriggerApp].self, from: data)) ?? [])
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func policy(for bundleID: String) -> AppPolicy? {
        all().first { $0.bundleID == bundleID }?.policy
    }

    static func set(bundleID: String, name: String, policy: AppPolicy) {
        var apps = all()
        if let i = apps.firstIndex(where: { $0.bundleID == bundleID }) {
            apps[i].policy = policy
            if !name.isEmpty { apps[i].name = name }
        } else {
            apps.append(TriggerApp(bundleID: bundleID, name: name.isEmpty ? bundleID : name, policy: policy))
        }
        save(apps)
    }

    static func remove(bundleID: String) {
        save(all().filter { $0.bundleID != bundleID })
    }

    private static func save(_ apps: [TriggerApp]) {
        if let data = try? JSONEncoder().encode(apps) {
            UserDefaults.standard.set(data, forKey: SettingsKeys.appPolicies)
        }
    }

    /// Имя приложения по bundle id (для отображения), даже если оно не запущено.
    static func displayName(for bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName ?? bundleID
    }
}
