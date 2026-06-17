import AVFoundation

/// Запись микрофона через AVAudioEngine в чанки AAC.
final class MicRecorder {
    private let engine = AVAudioEngine()
    private var sink: ChunkedAudioFile?

    func start(directory: URL) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw VaqloError(L("err.micUnavailable"))
        }
        let sink = ChunkedAudioFile(directory: directory, prefix: "mic", processingFormat: format)
        self.sink = sink
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            sink.write(buffer)
        }
        try engine.start()
    }

    var chunksSnapshot: [ChunkedAudioFile.ChunkInfo] { sink?.chunksSnapshot ?? [] }

    func stop() -> [ChunkedAudioFile.ChunkInfo] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        sink?.close()
        let chunks = sink?.chunks ?? []
        sink = nil
        return chunks
    }
}

struct VaqloError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
