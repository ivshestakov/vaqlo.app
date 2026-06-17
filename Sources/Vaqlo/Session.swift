import Foundation

/// Одна сессия записи = папка recordings/<YYYY-MM-DD>/<HHMMSS>/
struct Session: Identifiable, Equatable {
    enum State: Equatable {
        case recording      // идёт прямо сейчас
        case pending        // есть аудио, транскрипта нет
        case transcribing
        case done           // есть transcript.md
    }

    let id: String          // "2026-06-12/001210"
    let directory: URL
    let start: Date
    var end: Date?
    var state: State

    var duration: TimeInterval { (end ?? Date()).timeIntervalSince(start) }

    var transcriptMD: URL { directory.appendingPathComponent("transcript.md") }
    var transcriptJSON: URL { directory.appendingPathComponent("transcript.json") }
    var metadataURL: URL { directory.appendingPathComponent("session.json") }

    func loadMetadata() -> SessionMetadata? {
        guard let data = try? Data(contentsOf: metadataURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SessionMetadata.self, from: data)
    }

    func audioFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "m4a" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

/// Грубая классификация: что это была за запись.
enum SessionClassifier {
    private static let meetingApps: [(keyword: String, title: String)] = [
        ("zoom", "Zoom"), ("teams", "Microsoft Teams"), ("meet", "Google Meet"),
        ("webex", "Webex"), ("facetime", "FaceTime"), ("skype", "Skype"),
        ("discord", "Discord"), ("телемост", "Телемост"), ("контур.толк", "Контур.Толк"),
    ]

    /// Возвращает человекочитаемую классификацию сессии.
    /// metadata — таймлайн активных приложений; lines — транскрипт (если уже есть).
    static func classify(metadata: SessionMetadata?, lines: [TranscriptLine]?) -> String {
        let appNames = (metadata?.frontmostApps ?? []).compactMap(\.name)
        for name in appNames {
            let lower = name.lowercased()
            if let match = meetingApps.first(where: { lower.contains($0.keyword) }) {
                return L("class.meeting", match.title)
            }
        }
        guard let lines else { return L("class.notTranscribed") }
        let hasSystemSpeech = lines.contains { $0.source == "sys" }
        let hasMicSpeech = lines.contains { $0.source == "mic" }
        switch (hasMicSpeech, hasSystemSpeech) {
        case (true, true): return L("class.callOrMedia")
        case (false, true): return L("class.systemAudio")
        case (true, false): return L("class.offline")
        case (false, false): return L("class.silence")
        }
    }
}

/// Реплика объединённого транскрипта.
struct TranscriptLine: Codable, Identifiable, Equatable {
    var id: String { "\(time.timeIntervalSince1970)-\(source)" }
    let time: Date
    let source: String   // "mic" | "sys"
    let label: String    // "Я" | "Компьютер" (в старых транскриптах — имя приложения)
    let app: String?     // приложение в фокусе в этот момент — контекст, НЕ источник звука
    var speaker: String? // распознанный голос: «я», «Иван», «Спикер 1»; nil — без диаризации
    let text: String
}

/// Чистка типового мусора Whisper: галлюцинации на тишине, зацикленные повторы
/// и эхо (микрофон слышит то же, что играет из динамиков).
enum TranscriptCleaner {
    // Фразы-галлюцинации из обучающих данных (субтитры YouTube).
    private static let junkPhrases = [
        "thanks for watching", "subscribe to", "субтитр", "продолжение следует",
        "ставьте лайк", "подписывайтесь на канал", "dimatorzok",
    ]

    static func clean(_ input: [TranscriptLine]) -> [TranscriptLine] {
        func norm(_ s: String) -> String {
            s.lowercased()
                .filter { $0.isLetter || $0.isNumber || $0 == " " }
                .trimmingCharacters(in: .whitespaces)
        }

        var result: [TranscriptLine] = []
        for line in input {
            let n = norm(line.text)
            if n.isEmpty { continue }
            if junkPhrases.contains(where: { n.contains($0) }) { continue }
            // Зацикленный повтор: тот же источник, тот же текст, почти без паузы.
            if let last = result.last(where: { $0.source == line.source }),
               norm(last.text) == n,
               line.time.timeIntervalSince(last.time) < 6 {
                continue
            }
            result.append(line)
        }

        // Эхо: реплика из микрофона дублирует системную в пределах ±3 с — оставляем системную.
        let sysLines = result.filter { $0.source == "sys" }
        return result.filter { line in
            guard line.source == "mic" else { return true }
            return !sysLines.contains {
                abs($0.time.timeIntervalSince(line.time)) <= 3 && norm($0.text) == norm(line.text)
            }
        }
    }
}

/// Склейка подряд идущих реплик одного источника в одно «сообщение».
struct TranscriptGroup: Identifiable {
    let id: String
    let source: String
    let label: String
    let app: String?
    let start: Date
    let lines: [TranscriptLine]
}

enum TranscriptGrouper {
    /// Группируем, пока источник и приложение в фокусе не меняются, а пауза < maxGap.
    static func group(_ lines: [TranscriptLine], maxGap: TimeInterval = 90) -> [TranscriptGroup] {
        var groups: [TranscriptGroup] = []
        var current: [TranscriptLine] = []

        func flush() {
            guard let first = current.first else { return }
            groups.append(TranscriptGroup(
                id: first.id,
                source: first.source,
                label: displayLabel(first),
                app: focusApp(first),
                start: first.time,
                lines: current
            ))
            current = []
        }

        for line in lines {
            if let last = current.last,
               last.source == line.source,
               displayLabel(last) == displayLabel(line),
               focusApp(last) == focusApp(line),
               line.time.timeIntervalSince(last.time) <= maxGap {
                current.append(line)
            } else {
                flush()
                current = [line]
            }
        }
        flush()
        return groups
    }

    static var selfLabel: String {
        let label = (UserDefaults.standard.string(forKey: SettingsKeys.selfLabel) ?? "").trimmingCharacters(in: .whitespaces)
        return label.isEmpty ? L("self.default") : label
    }

    static func displayLabel(_ line: TranscriptLine) -> String {
        if let speaker = line.speaker, !speaker.isEmpty { return speaker }
        return line.source == "mic" ? selfLabel : L("speaker.computer")
    }

    /// Приложение в фокусе; для старых транскриптов имя приложения лежало в label.
    static func focusApp(_ line: TranscriptLine) -> String? {
        if let app = line.app { return app }
        // Старые транскрипты: системная подпись = имя приложения (не служебная метка).
        let known = ["Я", "я", "me", "Компьютер", "Комп'ютер", "Computer", "Система", "Equipo", "Ordinateur", "Computador"]
        if line.source == "sys", !known.contains(line.label) {
            return line.label
        }
        return nil
    }
}

/// Скан папки записей; единственный источник правды о сессиях для UI.
@MainActor
final class SessionLibrary: ObservableObject {
    @Published private(set) var sessions: [Session] = []

    /// id сессий, которые сейчас в работе у транскрайбера (state поверх файлов).
    var transcribingIDs: Set<String> = [] { didSet { rescan() } }
    var recordingID: String?

    func rescan() {
        let fm = FileManager.default
        var result: [Session] = []
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd/HHmmss"
        dayFormatter.timeZone = .current

        let days = (try? fm.contentsOfDirectory(at: Storage.recordings, includingPropertiesForKeys: nil)) ?? []
        for day in days where day.hasDirectoryPath {
            let sessionDirs = (try? fm.contentsOfDirectory(at: day, includingPropertiesForKeys: nil)) ?? []
            for dir in sessionDirs where dir.hasDirectoryPath {
                let id = "\(day.lastPathComponent)/\(dir.lastPathComponent)"
                guard let start = dayFormatter.date(from: id) else { continue }

                var end: Date?
                if let data = try? Data(contentsOf: dir.appendingPathComponent("session.json")) {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    if let metadata = try? decoder.decode(SessionMetadata.self, from: data) {
                        // end == nil у прерванной записи — берём конец последнего чанка.
                        end = metadata.end
                            ?? (metadata.micChunks + metadata.systemChunks).map(\.end).max()
                    }
                }

                let hasTranscript = fm.fileExists(atPath: dir.appendingPathComponent("transcript.md").path)
                let state: Session.State
                if id == recordingID {
                    state = .recording
                } else if transcribingIDs.contains(id) {
                    state = .transcribing
                } else if hasTranscript {
                    state = .done
                } else {
                    state = .pending
                }
                result.append(Session(id: id, directory: dir, start: start, end: end, state: state))
            }
        }
        sessions = result.sorted { $0.start > $1.start }
    }

    var pending: [Session] { sessions.filter { $0.state == .pending } }

    func sessions(onDay day: Date) -> [Session] {
        let cal = Calendar.current
        return sessions.filter { cal.isDate($0.start, inSameDayAs: day) }
    }
}
