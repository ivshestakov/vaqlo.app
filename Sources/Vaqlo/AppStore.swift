import AppKit
import AVFoundation
import Combine
import Foundation
import WidgetKit

/// Центральное состояние приложения. Singleton, чтобы AppDelegate (хоткей, иконка)
/// и SwiftUI-вьюхи работали с одним и тем же объектом.
@MainActor
final class AppStore: ObservableObject {
    static let shared = AppStore()

    @Published private(set) var isRecording = false
    @Published var recordingError: String?
    /// Инкрементируется при изменении транскриптов извне (переименование спикера) — вьюхи перечитывают.
    @Published var transcriptRevision = 0

    let recorder = RecordingController()
    let library = SessionLibrary()
    let models = ModelManager()
    lazy var transcriber = Transcriber(library: library, models: models)
    lazy var summarizer = Summarizer(models: models)

    private var hotKey: HotKey?
    private var scheduleTimer: Timer?
    private var lastScheduledRun: Date?
    private var lastPurge = Date()
    private var cancellables: Set<AnyCancellable> = []

    // Автодетект встреч
    private var meetingTimer: Timer?
    private var micWasActive = false
    private var startedByMeeting = false
    private var micFreeSince: Date?
    /// id, которому уже показали уведомление в этой «встрече» — чтобы не спамить.
    private var notifiedThisMeeting = false

    private init() {
        Storage.prepare()
        SettingsKeys.registerDefaults()
        TrashKeeper.purgeExpired()
        library.rescan()

        recorder.onStateChange = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.isRecording = self.recorder.isRecording
                if !self.isRecording { self.startedByMeeting = false }
                self.library.recordingID = self.recorder.currentSessionID
                self.library.rescan()
                self.syncControlCenterState()
            }
        }

        // Тоггл из контрола Control Center приходит distributed-нотификацией.
        DistributedNotificationCenter.default().addObserver(
            forName: VaqloShared.toggleNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                let store = AppStore.shared
                let requested = VaqloShared.defaults?.bool(forKey: VaqloShared.requestedKey) ?? !store.isRecording
                if requested != store.isRecording {
                    store.toggleRecording()
                }
            }
        }

        // Контрол показывает число необработанных сессий — обновляем при каждом рескане.
        library.$sessions
            .map { $0.filter { $0.state == .pending }.count }
            .removeDuplicates()
            .sink { [weak self] _ in self?.syncControlCenterState() }
            .store(in: &cancellables)

        transcriber.onSessionDone = { [weak self] session in
            guard let self, UserDefaults.standard.bool(forKey: SettingsKeys.autoSummarize) else { return }
            self.summarizer.summarize(session)
        }

        // Раньше здесь был «republish-шторм»: любое изменение в дочернем объекте
        // (прогресс загрузки модели/транскрибации — десятки раз в секунду) перерисовывало
        // всё окно и роняло SwiftUI/DesignLibrary под нагрузкой. Теперь каждая вьюха
        // наблюдает нужный ей объект напрямую (@ObservedObject store.models / .transcriber / …),
        // поэтому высокочастотные изменения перерисовывают только свой маленький фрагмент.

        // Минутный тик: расписание транскрибации + ежечасная чистка корзины.
        scheduleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in AppStore.shared.minuteTick() }
        }

        // Автодетект встреч: опрос микрофона раз в 4 секунды.
        meetingTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { _ in
            Task { @MainActor in AppStore.shared.meetingTick() }
        }

        syncControlCenterState()
    }

    func toggleRecording() {
        if isRecording {
            recorder.stop()
        } else {
            requestMicAccessThenStart()
        }
    }

    // MARK: - Автодетект встреч

    private func meetingTick() {
        let mode = UserDefaults.standard.integer(forKey: SettingsKeys.meetingDetection)
        let mics = MeetingDetector.appsUsingMic()
        let micActive = !mics.isEmpty

        defer { micWasActive = micActive }

        // Микрофон освободился → автостарт пора останавливать.
        if !micActive {
            notifiedThisMeeting = false
            if isRecording, startedByMeeting,
               UserDefaults.standard.bool(forKey: SettingsKeys.meetingAutoStop) {
                if micFreeSince == nil { micFreeSince = Date() }
                // 20 секунд тишины — встреча действительно закончилась, а не пауза.
                else if Date().timeIntervalSince(micFreeSince!) > 20 {
                    recorder.stop()
                    startedByMeeting = false
                    micFreeSince = nil
                }
            }
            return
        }
        micFreeSince = nil

        // Новый триггер (микрофон только что заняли) и мы ещё не пишем.
        guard mode != 0, !isRecording, !micWasActive, !notifiedThisMeeting,
              let mic = mics.first else { return }
        notifiedThisMeeting = true
        let appName = mic.displayName

        // Политика на это приложение определяет поведение.
        switch MeetingPolicies.policy(for: mic.bundleID) {
        case .auto:
            startedByMeeting = true
            requestMicAccessThenStart()
            Notifier.show(title: L("notif.auto.title"), body: L("notif.auto.body", appName))
        case .never:
            break  // диктовщики и прочее — игнорируем молча
        case .ask:
            Notifier.askToRecord(appName: appName)
        case nil:
            // Первая встреча с этим приложением — спросить, какую политику применять.
            Notifier.askFirstSeen(appName: appName, bundleID: mic.bundleID)
        }
    }

    /// Вызывается из уведомления «Записать».
    func startRecordingFromNotification() {
        guard !isRecording else { return }
        startedByMeeting = true
        requestMicAccessThenStart()
    }

    /// Выбор политики из уведомления при первой встрече с приложением.
    func applyFirstSeenChoice(bundleID: String, name: String, policy: AppPolicy) {
        MeetingPolicies.set(bundleID: bundleID, name: name, policy: policy)
        if policy != .never { startRecordingFromNotification() }
    }

    // MARK: - Горячая клавиша

    func registerHotKey() {
        let defaults = UserDefaults.standard
        let code = UInt32(defaults.integer(forKey: SettingsKeys.hotKeyCode))
        let modifiers = UInt32(defaults.integer(forKey: SettingsKeys.hotKeyModifiers))
        hotKey = nil
        hotKey = HotKey(keyCode: code, modifiers: modifiers) {
            Task { @MainActor in AppStore.shared.toggleRecording() }
        }
    }

    var hotKeyDescription: String {
        let defaults = UserDefaults.standard
        return HotKeyFormat.description(
            keyCode: UInt32(defaults.integer(forKey: SettingsKeys.hotKeyCode)),
            modifiers: UInt32(defaults.integer(forKey: SettingsKeys.hotKeyModifiers))
        )
    }

    private func requestMicAccessThenStart() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            recorder.start()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    if granted {
                        AppStore.shared.recorder.start()
                    } else {
                        AppStore.shared.recordingError = L("err.mic")
                    }
                }
            }
        default:
            recordingError = L("err.mic")
        }
    }

    // MARK: - Удаление и корзина

    func deleteSession(_ session: Session) {
        TrashKeeper.trashSession(session)
        library.rescan()
    }

    func restoreFromTrash(_ entry: TrashEntry) {
        do {
            try TrashKeeper.restore(entry)
        } catch {
            recordingError = L("msg.restoreFailed", error.localizedDescription)
        }
        library.rescan()
    }

    // MARK: - Спикеры

    /// Переименовывает спикера в сессии и запоминает голос в библиотеке —
    /// на следующих встречах он распознается автоматически.
    func renameSpeaker(in session: Session, from oldLabel: String, to rawName: String) {
        let newName = rawName.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty, newName != oldLabel else { return }

        // Голосовой отпечаток — в библиотеку.
        var speakers = SessionSpeaker.load(for: session)
        if let index = speakers.firstIndex(where: { $0.label == oldLabel }) {
            speakers[index].label = newName
            VoiceLibrary.enroll(name: newName, embedding: speakers[index].embedding)
            SessionSpeaker.save(speakers, for: session)
        }

        // Транскрипт: json + md.
        guard let data = try? Data(contentsOf: session.transcriptJSON) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var lines = try? decoder.decode([TranscriptLine].self, from: data) else { return }
        for index in lines.indices where lines[index].speaker == oldLabel {
            lines[index].speaker = newName
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(lines).write(to: session.transcriptJSON)
        try? Transcriber.markdown(for: session, lines: lines)
            .data(using: .utf8)?.write(to: session.transcriptMD)

        transcriptRevision += 1
    }

    // MARK: - Синхронизация с Control Center

    private func syncControlCenterState() {
        let shared = VaqloShared.defaults
        shared?.set(isRecording, forKey: VaqloShared.isRecordingKey)
        if let start = recorder.sessionStart, isRecording {
            shared?.set(start.timeIntervalSince1970, forKey: VaqloShared.startedAtKey)
        } else {
            shared?.removeObject(forKey: VaqloShared.startedAtKey)
        }
        shared?.set(library.pending.count, forKey: VaqloShared.pendingKey)
        if #available(macOS 26.0, *) {
            ControlCenter.shared.reloadControls(ofKind: VaqloShared.controlKind)
        }
    }

    // MARK: - Расписание

    private func minuteTick() {
        if Date().timeIntervalSince(lastPurge) >= 3600 {
            lastPurge = Date()
            TrashKeeper.purgeExpired()
        }
        scheduledTranscriptionTick()
    }

    private func scheduledTranscriptionTick() {
        let defaults = UserDefaults.standard
        let mode = defaults.integer(forKey: SettingsKeys.scheduleMode)
        guard mode != 0, !library.pending.isEmpty else { return }

        let now = Date()
        switch mode {
        case 1:
            let hours = max(1, defaults.integer(forKey: SettingsKeys.scheduleIntervalHours))
            if let last = lastScheduledRun, now.timeIntervalSince(last) < Double(hours) * 3600 { return }
        case 2:
            let target = defaults.integer(forKey: SettingsKeys.scheduleDailyMinutes)
            let cal = Calendar.current
            let nowMinutes = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
            guard nowMinutes == target else { return }
            if let last = lastScheduledRun, cal.isDate(last, inSameDayAs: now) { return }
        default:
            return
        }

        lastScheduledRun = now
        transcriber.transcribeAllPending()
    }

    // MARK: - Экспорт

    /// Выгружает transcript.md сессии в папку экспорта; возвращает путь или кидает ошибку.
    func export(_ session: Session) throws -> URL {
        guard let folder = UserDefaults.standard.string(forKey: SettingsKeys.exportFolder), !folder.isEmpty else {
            throw VaqloError(L("err.exportFolder"))
        }
        let name = session.id.replacingOccurrences(of: "/", with: "_") + ".md"
        let target = URL(fileURLWithPath: folder).appendingPathComponent(name)
        var content = try String(contentsOf: session.transcriptMD, encoding: .utf8)
        if let summary = try? String(contentsOf: Summarizer.summaryURL(for: session), encoding: .utf8) {
            content = "\(summary)\n\n---\n\n\(content)"
        }
        try content.write(to: target, atomically: true, encoding: .utf8)
        return target
    }
}
