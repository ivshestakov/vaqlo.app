import AVFoundation

/// Пишет AAC (.m4a) чанками фиксированной длительности: mic_0001.m4a, mic_0002.m4a, …
/// Ротация происходит синхронно в потоке записи — открытие файла занимает миллисекунды
/// и случается раз в 5 минут, для v1 это приемлемо.
final class ChunkedAudioFile {
    static let chunkDuration: TimeInterval = 300

    private let directory: URL
    private let prefix: String
    private let processingFormat: AVAudioFormat
    private let lock = NSLock()

    private var file: AVAudioFile?
    private var chunkIndex = 0
    private var chunkStart = Date()
    private var closed = false
    private(set) var chunks: [ChunkInfo] = []

    struct ChunkInfo: Codable {
        let file: String
        /// ISO8601 в session.json хранит только целые секунды — для сведения дорожек этого мало.
        let start: Date
        var end: Date
        /// Момент первого сэмпла чанка (Unix-время с долями секунды, по host time аудио-буфера).
        /// Нет в записях до 0.1.6 — там остаётся округлённый `start`.
        var startTime: TimeInterval? = nil

        /// Точное начало чанка: по нему mic и sys кладутся на общую шкалу. С округлённым
        /// `start` дорожки расходились на 0,05–0,6 с, и голос из динамиков, попавший
        /// в микрофон, звучал в плеере вторым эхом.
        var exactStart: Date { startTime.map(Date.init(timeIntervalSince1970:)) ?? start }
    }

    init(directory: URL, prefix: String, processingFormat: AVAudioFormat, startIndex: Int = 0) {
        self.directory = directory
        self.prefix = prefix
        self.processingFormat = processingFormat
        self.chunkIndex = startIndex
    }

    /// `hostTime` — host time первого сэмпла буфера (из аудио-колбэка); по нему считается
    /// точное начало чанка. Без него берётся текущий момент, а это на задержку буфера позже.
    func write(_ buffer: AVAudioPCMBuffer, hostTime: UInt64? = nil) {
        lock.lock()
        defer { lock.unlock() }
        // После close() писать нельзя: аудио-колбэк может пережить остановку
        // (teardown Core Audio не гарантирован) — иначе файл «воскреснет».
        guard !closed else { return }
        do {
            if file == nil || Date().timeIntervalSince(chunkStart) >= Self.chunkDuration {
                try rotate(firstSampleAt: Self.date(ofHostTime: hostTime))
            }
            try file?.write(from: buffer)
        } catch {
            NSLog("ChunkedAudioFile[\(prefix)] write failed: \(error)")
        }
    }

    /// Потокобезопасный снимок списка чанков (для промежуточных записей session.json).
    var chunksSnapshot: [ChunkInfo] {
        lock.lock()
        defer { lock.unlock() }
        return chunks
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        finishCurrentChunk()
        file = nil
        closed = true
    }

    /// Перевод host time аудио-буфера в настенное время.
    private static func date(ofHostTime hostTime: UInt64?) -> Date {
        let now = Date()
        guard let hostTime, hostTime > 0 else { return now }
        let age = AVAudioTime.seconds(forHostTime: mach_absolute_time()) - AVAudioTime.seconds(forHostTime: hostTime)
        return now.addingTimeInterval(-age)
    }

    private func rotate(firstSampleAt start: Date) throws {
        finishCurrentChunk()
        chunkIndex += 1
        chunkStart = start
        let name = String(format: "%@_%04d.m4a", prefix, chunkIndex)
        let url = directory.appendingPathComponent(name)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: processingFormat.sampleRate,
            AVNumberOfChannelsKey: processingFormat.channelCount,
            AVEncoderBitRateKey: 64_000,
        ]
        file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: processingFormat.commonFormat,
            interleaved: processingFormat.isInterleaved
        )
        chunks.append(ChunkInfo(file: name, start: chunkStart, end: chunkStart,
                                startTime: chunkStart.timeIntervalSince1970))
    }

    private func finishCurrentChunk() {
        guard file != nil else { return }
        if !chunks.isEmpty { chunks[chunks.count - 1].end = Date() }
        file = nil // деинициализация AVAudioFile финализирует контейнер
    }
}
