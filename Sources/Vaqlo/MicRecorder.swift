import AVFoundation

/// Запись микрофона через AVAudioEngine в чанки AAC.
/// Устойчива к смене аудио-маршрута/устройства во время звонка: AVAudioEngine при этом
/// останавливается (config-change) и сам не возобновляется — мы перезапускаем его,
/// плюс watchdog поднимает движок, если он встал по любой причине (прерывание и т.п.).
final class MicRecorder {
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "vaqlo.mic")

    private var sink: ChunkedAudioFile?
    private var directory: URL?
    private var collected: [ChunkedAudioFile.ChunkInfo] = []  // чанки от предыдущих перезапусков
    private var observer: NSObjectProtocol?
    private var watchdog: Timer?
    private var running = false
    private var lastBufferAt = Date()
    private let bufferLock = NSLock()

    func start(directory: URL) throws {
        self.directory = directory
        collected = []
        try setup()  // первичная установка; бросает, если микрофон недоступен
        running = true

        // Смена аудио-конфигурации (маршрут/устройство/частота) останавливает движок.
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.queue.async { self?.reconfigure(reason: "config change") }
        }

        // Watchdog: ловим и «движок встал», и «движок работает, но буферов нет»
        // (микрофон забрал другой процесс / увело вход во время звонка).
        DispatchQueue.main.async {
            self.watchdog = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                guard let self, self.running else { return }
                let stalled = !self.engine.isRunning || self.secondsSinceLastBuffer() > 4
                if stalled {
                    self.queue.async {
                        self.reconfigure(reason: self.engine.isRunning ? "no mic buffers" : "engine stopped")
                    }
                }
            }
        }
    }

    private func noteBuffer() {
        bufferLock.lock(); lastBufferAt = Date(); bufferLock.unlock()
    }

    private func secondsSinceLastBuffer() -> TimeInterval {
        bufferLock.lock(); defer { bufferLock.unlock() }
        return Date().timeIntervalSince(lastBufferAt)
    }

    private func setup() throws {
        guard let directory else { throw VaqloError(L("err.micUnavailable")) }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw VaqloError(L("err.micUnavailable"))
        }
        let sink = ChunkedAudioFile(directory: directory, prefix: "mic",
                                    processingFormat: format, startIndex: collected.count)
        self.sink = sink
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.noteBuffer()
            sink.write(buffer)
        }
        engine.prepare()
        try engine.start()
        noteBuffer()  // сбрасываем таймер, чтобы watchdog не сработал сразу
    }

    /// Закрыть текущий чанк-файл и переустановить движок (после смены конфигурации/останова).
    private func reconfigure(reason: String) {
        guard running else { return }
        NSLog("MicRecorder: перезапуск (\(reason))")
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
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
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        DispatchQueue.main.async { self.watchdog?.invalidate(); self.watchdog = nil }
        return queue.sync {
            engine.inputNode.removeTap(onBus: 0)
            if engine.isRunning { engine.stop() }
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
