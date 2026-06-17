import AppKit
import Foundation

/// Запись о файле/сессии, которые мы положили в системную Корзину.
struct TrashEntry: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case audio    // аудиофайлы после транскрибации (транскрипт остался в сессии)
        case session  // сессия целиком, удалённая пользователем
    }

    let id: String
    let kind: Kind
    let title: String
    let originalPath: String
    let trashedPath: String
    let date: Date

    var deleteAt: Date {
        let days = max(1, UserDefaults.standard.integer(forKey: SettingsKeys.retentionDays))
        return date.addingTimeInterval(Double(days) * 86_400)
    }

    var stillExists: Bool { FileManager.default.fileExists(atPath: trashedPath) }
}

/// Кладёт отработанное аудио и удалённые сессии в системную Корзину,
/// помнит, что положило, умеет восстанавливать и само чистит через N дней.
enum TrashKeeper {
    static func all() -> [TrashEntry] {
        load().filter(\.stillExists).sorted { $0.date > $1.date }
    }

    static func trashAudio(_ files: [URL], sessionTitle: String) {
        var entries = load()
        for file in files {
            if let trashed = moveToTrash(file) {
                entries.append(TrashEntry(
                    id: UUID().uuidString,
                    kind: .audio,
                    title: "\(sessionTitle) · \(file.lastPathComponent)",
                    originalPath: file.path,
                    trashedPath: trashed.path,
                    date: Date()
                ))
            }
        }
        save(entries)
    }

    static func trashSession(_ session: Session) {
        var entries = load()
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM HH:mm"
        if let trashed = moveToTrash(session.directory) {
            entries.append(TrashEntry(
                id: UUID().uuidString,
                kind: .session,
                title: L("trash.sessionTitle", formatter.string(from: session.start)),
                originalPath: session.directory.path,
                trashedPath: trashed.path,
                date: Date()
            ))
        }
        save(entries)
    }

    static func restore(_ entry: TrashEntry) throws {
        let original = URL(fileURLWithPath: entry.originalPath)
        try FileManager.default.createDirectory(
            at: original.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: URL(fileURLWithPath: entry.trashedPath), to: original)
        save(load().filter { $0.id != entry.id })
    }

    static func deleteNow(_ entry: TrashEntry) {
        try? FileManager.default.removeItem(atPath: entry.trashedPath)
        save(load().filter { $0.id != entry.id })
    }

    static func emptyAll() {
        for entry in load() {
            try? FileManager.default.removeItem(atPath: entry.trashedPath)
        }
        save([])
    }

    /// Вызывается при старте и раз в час: чистит то, чей срок хранения истёк.
    static func purgeExpired() {
        var remaining: [TrashEntry] = []
        for entry in load() {
            if entry.deleteAt <= Date() {
                try? FileManager.default.removeItem(atPath: entry.trashedPath)
            } else if entry.stillExists {
                remaining.append(entry)
            }
        }
        save(remaining)
    }

    // MARK: - Внутреннее

    private static func moveToTrash(_ url: URL) -> URL? {
        var resulting: NSURL?
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
            return resulting as URL?
        } catch {
            NSLog("TrashKeeper: не удалось убрать в корзину \(url.lastPathComponent): \(error)")
            return nil
        }
    }

    private static func load() -> [TrashEntry] {
        guard let data = try? Data(contentsOf: Storage.trashLog) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let entries = try? decoder.decode([TrashEntry].self, from: data) {
            return entries
        }
        // Старый формат (фаза 2): [{trashedURL, date}]
        struct Legacy: Codable { let trashedURL: URL; let date: Date }
        if let legacy = try? decoder.decode([Legacy].self, from: data) {
            return legacy.map {
                TrashEntry(
                    id: UUID().uuidString,
                    kind: .audio,
                    title: $0.trashedURL.lastPathComponent,
                    originalPath: $0.trashedURL.path,
                    trashedPath: $0.trashedURL.path,
                    date: $0.date
                )
            }
        }
        return []
    }

    private static func save(_ entries: [TrashEntry]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(entries).write(to: Storage.trashLog)
    }
}
