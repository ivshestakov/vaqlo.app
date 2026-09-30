import AVFoundation

/// Чистит дорожку микрофона сессии от эха собеседников (см. `EchoCanceller`) и
/// перезаписывает mic-чанки на месте. Запускается в фоне сразу после остановки записи
/// и ещё раз (синхронно) перед транскрибацией — на случай, если приложение закрыли раньше.
/// Обработанные чанки отмечаются в session.json (`echoCancelled`), повторно не трогаются.
enum EchoCleaner {
    private static let lock = NSLock()
    private static let queue = DispatchQueue(label: "vaqlo.echo", qos: .utility)

    static func cleanInBackground(directory: URL) {
        queue.async { clean(directory: directory) }
    }

    /// Синхронно. Параллельные вызовы для одной сессии ждут друг друга.
    static func clean(directory: URL) {
        lock.lock()
        defer { lock.unlock() }
        let metadataURL = directory.appendingPathComponent("session.json")
        guard var metadata = SessionMetadata.load(from: metadataURL) else { return }
        var done = Set(metadata.echoCancelled ?? [])

        for chunk in metadata.micChunks where !done.contains(chunk.file) {
            let url = directory.appendingPathComponent(chunk.file)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let started = Date()
            let outcome = cleanChunk(chunk, url: url, systemChunks: metadata.systemChunks, directory: directory)
            NSLog("EchoCleaner: \(chunk.file) — \(outcome) за \(String(format: "%.1f", Date().timeIntervalSince(started))) с")
            // Отмечаем и пропущенные (эха нет / файл не читается): повтор дал бы то же самое.
            done.insert(chunk.file)
            metadata.echoCancelled = metadata.micChunks.map(\.file).filter(done.contains)
            metadata.write(to: metadataURL)
        }
    }

    private static func cleanChunk(_ chunk: ChunkedAudioFile.ChunkInfo, url: URL,
                                   systemChunks: [ChunkedAudioFile.ChunkInfo], directory: URL) -> String {
        guard let (mic, rate) = readMono(url) else { return "не читается, пропущен" }
        let micStart = chunk.exactStart
        let micEnd = micStart.addingTimeInterval(Double(mic.count) / rate)

        // Опорный сигнал на шкале этого чанка — из всех sys-чанков, что его перекрывают.
        var reference = [Float](repeating: 0, count: mic.count)
        var covered = false
        for sys in systemChunks {
            guard sys.exactStart < micEnd.addingTimeInterval(2), sys.end > micStart.addingTimeInterval(-2) else { continue }
            let sysURL = directory.appendingPathComponent(sys.file)
            guard let (samples, _) = readMono(sysURL, sampleRate: rate) else { continue }
            let offset = Int((sys.exactStart.timeIntervalSince(micStart) * rate).rounded())
            let from = max(0, offset), to = min(mic.count, offset + samples.count)
            guard from < to else { continue }
            for i in from..<to { reference[i] = samples[i - offset] }
            covered = true
        }
        guard covered else { return "нет системного звука, пропущен" }

        guard let result = EchoCanceller.process(mic: mic, reference: reference, sampleRate: rate) else {
            return "эха не найдено, без изменений"
        }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vaqlo-aec-\(UUID().uuidString).m4a")
        do {
            try writeM4A(result.samples, sampleRate: rate, to: temp)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            return "не удалось записать (\(error.localizedDescription))"
        }
        return "эхо подавлено, задержка \(Int(result.delay * 1000)) мс"
    }

    /// Весь файл в моно Float32; `sampleRate` — привести к этой частоте (иначе родная).
    private static func readMono(_ url: URL, sampleRate: Double? = nil) -> ([Float], Double)? {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return nil }
        let source = file.processingFormat
        let rate = sampleRate ?? source.sampleRate
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: source, to: target),
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 65_536),
              let output = AVAudioPCMBuffer(pcmFormat: target,
                                            frameCapacity: AVAudioFrameCount(65_536 * rate / source.sampleRate) + 4_096)
        else { return nil }
        converter.downmix = true  // стерео системного звука → сумма каналов, а не левый

        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(file.length) * rate / source.sampleRate) + 4_096)
        var finished = false
        while true {
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if !finished {
                    do { try file.read(into: input) } catch { input.frameLength = 0 }
                    finished = input.frameLength == 0
                }
                if finished {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return input
            }
            if status == .error { return nil }
            if output.frameLength > 0, let data = output.floatChannelData {
                samples.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
            }
            if status == .endOfStream { break }
        }
        return samples.isEmpty ? nil : (samples, rate)
    }

    /// Те же настройки AAC, что у `ChunkedAudioFile`.
    private static func writeM4A(_ samples: [Float], sampleRate: Double, to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let step = 65_536
        var index = 0
        while index < samples.count {
            let count = min(step, samples.count - index)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count)) else {
                throw VaqloError("Couldn't allocate audio buffer")
            }
            buffer.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer {
                buffer.floatChannelData![0].update(from: $0.baseAddress! + index, count: count)
            }
            try file.write(from: buffer)
            index += count
        }
        // Файл финализируется при освобождении `file` — на выходе из функции.
    }
}
