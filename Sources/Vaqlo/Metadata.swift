import AppKit
import Foundation

/// Сэмплирует активное приложение раз в 5 секунд; пишет точку только при смене.
/// Это даст транскрипту контекст «в 14:02 был активен Zoom».
final class FrontmostAppSampler {
    struct Sample: Codable {
        let time: Date
        let bundleID: String?
        let name: String?
    }

    private var timer: Timer?
    private var samples: [Sample] = []

    func start() {
        samples = []
        record()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.record()
        }
    }

    func stop() -> [Sample] {
        timer?.invalidate()
        timer = nil
        return samples
    }

    /// Текущий таймлайн (для промежуточной записи session.json во время записи).
    var snapshot: [Sample] { samples }

    private func record() {
        let app = NSWorkspace.shared.frontmostApplication
        let sample = Sample(time: Date(), bundleID: app?.bundleIdentifier, name: app?.localizedName)
        if samples.last?.bundleID != sample.bundleID {
            samples.append(sample)
        }
    }
}

struct SessionMetadata: Codable {
    let start: Date
    /// nil — запись ещё идёт (или была прервана аварийно).
    let end: Date?
    let micChunks: [ChunkedAudioFile.ChunkInfo]
    let systemChunks: [ChunkedAudioFile.ChunkInfo]
    let frontmostApps: [FrontmostAppSampler.Sample]
    /// Таймлайн «кто говорит» из приложения встречи (Slack/Zoom). nil в старых записях.
    var activeSpeakers: [ActiveSpeakerSample]?
    /// Встреча из календаря (название + участники), если нашлась. nil в старых записях.
    var meeting: MeetingInfo?
    /// mic-чанки, уже прошедшие подавление эха (`EchoCleaner`). nil — ни один.
    var echoCancelled: [String]?

    static func load(from url: URL) -> SessionMetadata? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SessionMetadata.self, from: data)
    }

    func write(to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(self).write(to: url, options: .atomic)
        } catch {
            NSLog("SessionMetadata write failed: \(error)")
        }
    }
}
