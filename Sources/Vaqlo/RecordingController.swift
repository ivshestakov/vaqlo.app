import AppKit
import Foundation

/// Координатор сессии записи: микрофон + системный звук + метаданные.
final class RecordingController {
    private let mic = MicRecorder()
    private let system = SystemAudioRecorder()
    private let appSampler = FrontmostAppSampler()
    private let speakerSampler = ActiveSpeakerSampler()

    private(set) var isRecording = false
    private(set) var sessionStart: Date?
    /// "2026-06-12/001210" — совпадает с Session.id
    private(set) var currentSessionID: String?
    private var sessionDirectory: URL?
    private var metadataTimer: Timer?

    var onStateChange: (() -> Void)?

    func start() {
        guard !isRecording else { return }
        let start = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd/HHmmss"
        let id = formatter.string(from: start)
        let dir = Storage.recordings.appendingPathComponent(id)

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try system.start(directory: dir)
        } catch {
            _ = system.stop()
            showError(error)
            return
        }

        // Микрофон недоступен (смена аудио-устройства, вход занят) — сессию не бросаем:
        // системный звук уже пишется, а MicRecorder продолжит поднимать вход watchdog-ом.
        do {
            try mic.start(directory: dir)
        } catch {
            NSLog("RecordingController: микрофон не стартовал (\(error.localizedDescription)) — пишем системный звук, mic поднимет watchdog")
        }

        appSampler.start()
        speakerSampler.start()
        sessionDirectory = dir
        sessionStart = start
        currentSessionID = id
        isRecording = true

        // session.json пишется сразу и обновляется каждую минуту: если процесс убьют,
        // метаданные и завершённые чанки не потеряются.
        writeMetadata(end: nil)
        metadataTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.writeMetadata(end: nil)
        }

        onStateChange?()
    }

    private func writeMetadata(end: Date?) {
        guard let dir = sessionDirectory, let start = sessionStart else { return }
        SessionMetadata(
            start: start,
            end: end,
            micChunks: mic.chunksSnapshot,
            systemChunks: system.chunksSnapshot,
            frontmostApps: appSampler.snapshot,
            activeSpeakers: speakerSampler.snapshot,
            meeting: end.flatMap { CalendarService.meeting(start: start, end: $0) }
        ).write(to: dir.appendingPathComponent("session.json"))
    }

    func stop() {
        guard isRecording else { return }
        metadataTimer?.invalidate()
        metadataTimer = nil
        let micChunks = mic.stop()
        let sysChunks = system.stop()
        let appTimeline = appSampler.stop()
        let speakerTimeline = speakerSampler.stop()

        if let dir = sessionDirectory, let start = sessionStart {
            let end = Date()
            let metadata = SessionMetadata(
                start: start,
                end: end,
                micChunks: micChunks,
                systemChunks: sysChunks,
                frontmostApps: appTimeline,
                activeSpeakers: speakerTimeline,
                meeting: CalendarService.meeting(start: start, end: end)
            )
            metadata.write(to: dir.appendingPathComponent("session.json"))
            // Звонок через динамики → собеседники есть и в микрофоне; чистим, пока запись свежая.
            EchoCleaner.cleanInBackground(directory: dir)
        }

        sessionDirectory = nil
        sessionStart = nil
        currentSessionID = nil
        isRecording = false
        onStateChange?()
    }

    private func showError(_ error: Error) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = L("err.startFailed")
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}
