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
    private(set) var chunks: [ChunkInfo] = []

    struct ChunkInfo: Codable {
        let file: String
        let start: Date
        var end: Date
    }

    init(directory: URL, prefix: String, processingFormat: AVAudioFormat) {
        self.directory = directory
        self.prefix = prefix
        self.processingFormat = processingFormat
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        do {
            if file == nil || Date().timeIntervalSince(chunkStart) >= Self.chunkDuration {
                try rotate()
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
    }

    private func rotate() throws {
        finishCurrentChunk()
        chunkIndex += 1
        chunkStart = Date()
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
        chunks.append(ChunkInfo(file: name, start: chunkStart, end: chunkStart))
    }

    private func finishCurrentChunk() {
        guard file != nil else { return }
        if !chunks.isEmpty { chunks[chunks.count - 1].end = Date() }
        file = nil // деинициализация AVAudioFile финализирует контейнер
    }
}
