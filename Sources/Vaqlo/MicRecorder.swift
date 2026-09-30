import AVFoundation
import ObjCExceptionCatcher

/// Запись микрофона через AVAudioEngine в чанки AAC.
/// Устойчива к смене аудио-маршрута/устройства во время звонка: AVAudioEngine при этом
/// останавливается (config-change) и сам не возобновляется — мы перезапускаем его,
/// плюс watchdog поднимает движок, если он встал по любой причине (прерывание и т.п.).
final class MicRecorder {
    /// Пересоздаётся на каждый setup(): AVAudioEngine на macOS кэширует формат входа,
    /// снятый при создании узла, и НЕ обновляет его при смене частоты железа. Когда
    /// Bluetooth-гарнитура уходит в HFP (48 000 → 16 000 Гц), у старого экземпляра
    /// `inputNode.outputFormat` навсегда остаётся 48 кГц, и `engine.start()` падает
    /// с «Format mismatch» на каждой попытке watchdog-а — микрофон не поднимается
    /// до конца встречи. Лечится только новым экземпляром движка.
    private var engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "vaqlo.mic")

    private var sink: ChunkedAudioFile?
    private var directory: URL?
    private var collected: [ChunkedAudioFile.ChunkInfo] = []  // чанки от предыдущих перезапусков
    private var observer: NSObjectProtocol?
    private var watchdog: Timer?
    private var running = false
    private var lastBufferAt = Date()
    /// Время последнего реального аудио-буфера от микрофона (не сбрасывается перезапусками).
    private var lastRealBufferAt: Date?
    private var startedAt = Date()
    private var notifiedSilence = false
    private let bufferLock = NSLock()

    /// Бросает, только если микрофон недоступен прямо сейчас, — но recovery-механика
    /// (config-change observer + watchdog) уже установлена, так что при живой сессии
    /// вход продолжит подниматься сам, когда микрофон вернётся.
    func start(directory: URL) throws {
        self.directory = directory
        collected = []
        startedAt = Date()
        lastRealBufferAt = nil
        notifiedSilence = false
        running = true

        // Watchdog: ловим и «движок встал», и «движок работает, но буферов нет»
        // (микрофон забрал другой процесс / увело вход во время звонка).
        // Проверка идёт на queue: там же живёт engine, менять его из двух потоков нельзя.
        DispatchQueue.main.async {
            self.watchdog = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                guard let self, self.running else { return }
                self.queue.async {
                    guard self.running else { return }
                    let alive = self.engine.isRunning
                    if !alive || self.secondsSinceLastBuffer() > 4 {
                        self.reconfigure(reason: alive ? "no mic buffers" : "engine stopped")
                    }
                }
                self.notifyIfSilent()
            }
        }

        try queue.sync { try setup() }
    }

    /// Микрофон не дал ни одного буфера >30 с (перезапуски не помогают) —
    /// сказать пользователю один раз за сессию: молчаливая потеря дорожки хуже.
    private func notifyIfSilent() {
        bufferLock.lock()
        let silentFor = Date().timeIntervalSince(lastRealBufferAt ?? startedAt)
        let shouldNotify = !notifiedSilence && silentFor > 30
        if shouldNotify { notifiedSilence = true }
        bufferLock.unlock()
        if shouldNotify {
            NSLog("MicRecorder: нет буферов от микрофона \(Int(silentFor)) с — уведомляем")
            Notifier.show(title: L("notif.micDown.title"), body: L("notif.micDown.body"))
        }
    }

    private func noteBuffer() {
        bufferLock.lock(); lastBufferAt = Date(); bufferLock.unlock()
    }

    private func noteRealBuffer() {
        bufferLock.lock()
        lastBufferAt = Date()
        lastRealBufferAt = lastBufferAt
        // Микрофон вернулся — взводим уведомление заново: за встречу вход
        // может отвалиться не один раз, и каждый провал стоит показать.
        notifiedSilence = false
        bufferLock.unlock()
    }

    private func secondsSinceLastBuffer() -> TimeInterval {
        bufferLock.lock(); defer { bufferLock.unlock() }
        return Date().timeIntervalSince(lastBufferAt)
    }

    private func setup() throws {
        guard let directory else { throw VaqloError(L("err.micUnavailable")) }

        // Новый движок на каждую попытку — только так подхватывается текущая частота входа
        // (см. комментарий у `engine`). Наблюдатель конфигурации привязан к конкретному
        // экземпляру, поэтому переустанавливается вместе с ним.
        let engine = AVAudioEngine()
        self.engine = engine
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.queue.async { self?.reconfigure(reason: "config change") }
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw VaqloError(L("err.micUnavailable"))
        }
        NSLog("MicRecorder: вход \(Int(format.sampleRate)) Гц / \(format.channelCount) кан.")
        let sink = ChunkedAudioFile(directory: directory, prefix: "mic",
                                    processingFormat: format, startIndex: collected.count)
        self.sink = sink
        // installTap/start бросают ObjC NSException, если формат входа успел стать
        // невалидным между проверкой выше и установкой (гонка со сменой устройства).
        // Swift NSException не ловит — без шима это abort всего процесса.
        var startError: Error?
        let objcError = VQCatchObjCException {
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, when in
                self?.noteRealBuffer()
                sink.write(buffer, hostTime: when.isHostTimeValid ? when.hostTime : nil)
            }
            self.engine.prepare()
            do { try self.engine.start() } catch { startError = error }
        }
        if let objcError { throw VaqloError(objcError.localizedDescription) }
        if let startError { throw VaqloError(startError.localizedDescription) }
        noteBuffer()  // сбрасываем таймер, чтобы watchdog не сработал сразу
    }

    /// Снять tap, остановить движок и отписаться от его уведомлений.
    /// Экземпляр после этого не переиспользуется — его заменит новый в `setup()`.
    private func teardownEngine() {
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        if let error = VQCatchObjCException({
            self.engine.inputNode.removeTap(onBus: 0)
            if self.engine.isRunning { self.engine.stop() }
        }) {
            NSLog("MicRecorder: исключение при остановке движка (\(error.localizedDescription))")
        }
    }

    /// Закрыть текущий чанк-файл и поднять микрофон заново (после смены конфигурации/останова).
    private func reconfigure(reason: String) {
        guard running else { return }
        NSLog("MicRecorder: перезапуск (\(reason))")
        teardownEngine()
        if let sink {
            sink.close()
            collected += sink.chunks
        }
        sink = nil
        do {
            try setup()
        } catch {
            NSLog("MicRecorder: не удалось перезапустить (\(error.localizedDescription)) — повтор через watchdog")
        }
    }

    var chunksSnapshot: [ChunkedAudioFile.ChunkInfo] {
        queue.sync { collected + (sink?.chunksSnapshot ?? []) }
    }

    func stop() -> [ChunkedAudioFile.ChunkInfo] {
        running = false
        DispatchQueue.main.async { self.watchdog?.invalidate(); self.watchdog = nil }
        return queue.sync {
            teardownEngine()
            sink?.close()
            let all = collected + (sink?.chunks ?? [])
            sink = nil
            collected = []
            return all
        }
    }
}

struct VaqloError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
