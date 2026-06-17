import Foundation

/// Транскрибация сессий: m4a → wav 16k (afconvert) → whisper-cli + диаризация (FluidAudio)
/// → объединённый транскрипт с именами голосов. После успеха аудио уезжает в Корзину.
@MainActor
final class Transcriber: ObservableObject {
    @Published private(set) var isWorking = false
    @Published private(set) var currentSessionID: String?
    @Published var lastError: String?

    private let library: SessionLibrary
    private let models: ModelManager
    private var queue: [Session] = []

    /// Вызывается после успешной транскрибации (для авто-саммари и т.п.).
    var onSessionDone: ((Session) -> Void)?

    init(library: SessionLibrary, models: ModelManager) {
        self.library = library
        self.models = models
    }

    func transcribe(_ session: Session) {
        enqueue([session])
    }

    func transcribeAllPending() {
        enqueue(library.pending)
    }

    private func enqueue(_ sessions: [Session]) {
        let eligible = sessions.filter { $0.state == .pending && !queue.contains($0) && $0.id != currentSessionID }
        guard !eligible.isEmpty else { return }
        guard models.readyModelFile != nil else {
            lastError = L("err.noModel")
            return
        }
        queue.append(contentsOf: eligible)
        library.transcribingIDs.formUnion(eligible.map(\.id))
        processNext()
    }

    private func processNext() {
        guard !isWorking, let session = queue.first else { return }
        guard let modelFile = models.readyModelFile else {
            queue.removeAll()
            library.transcribingIDs.removeAll()
            return
        }
        queue.removeFirst()
        isWorking = true
        currentSessionID = session.id
        lastError = nil

        Task.detached(priority: .utility) {
            let result: Result<Void, Error>
            do {
                try await TranscriptionJob(session: session, modelFile: modelFile).run()
                result = .success(())
            } catch {
                result = .failure(error)
            }
            await MainActor.run {
                switch result {
                case .failure(let error):
                    self.lastError = "\(session.id): \(error.localizedDescription)"
                case .success:
                    self.onSessionDone?(session)
                }
                self.library.transcribingIDs.remove(session.id)
                self.isWorking = false
                self.currentSessionID = nil
                self.library.rescan()
                self.processNext()
            }
        }
    }
}

/// Работа над одной сессией, выполняется вне главного потока.
private struct TranscriptionJob {
    let session: Session
    let modelFile: URL

    private struct WhisperSegment {
        let fromMS: Int
        let toMS: Int
        let text: String
    }

    private struct RawLine {
        let time: Date
        let source: String
        let app: String?
        let text: String
        let cluster: String?
    }

    func run() async throws {
        let metadata = session.loadMetadata()
        let audio = session.audioFiles()
        guard !audio.isEmpty else { throw VaqloError(L("err.noAudio")) }

        let diarizer = await DiarizationService.make() // nil → без разделения голосов
        let registry = SpeakerRegistry()
        var raw: [RawLine] = []
        var readableFiles = 0

        for file in audio {
            let name = file.deletingPathExtension().lastPathComponent // mic_0001 / sys_0001
            let source = name.hasPrefix("mic") ? "mic" : "sys"
            guard let chunkStart = chunkStartDate(name: name, metadata: metadata) else { continue }

            let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("vaqlo-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmpDir) }

            let wav = tmpDir.appendingPathComponent("audio.wav")
            do {
                // Чанк может быть не финализирован (приложение убили во время записи) —
                // пропускаем его, не роняя всю сессию.
                try runProcess("/usr/bin/afconvert", [
                    "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", file.path, wav.path,
                ])
            } catch {
                NSLog("Пропускаю нечитаемый чанк \(name): \(error.localizedDescription)")
                continue
            }
            readableFiles += 1

            let segments = try transcribeWav(wav, tmpDir: tmpDir)

            // Диаризация: локальные спикеры файла → кластеры сессии по отпечаткам.
            var turns: [DiarizationService.Turn] = []
            var clusterByLocalID: [String: String] = [:]
            if let diarizer {
                turns = diarizer.diarize(wav: wav)
                for (localID, speakerTurns) in Dictionary(grouping: turns, by: \.localSpeakerID) {
                    guard let dim = speakerTurns.first?.embedding.count, dim > 0 else { continue }
                    let duration = speakerTurns.reduce(0) { $0 + ($1.end - $1.start) }
                    var mean = [Float](repeating: 0, count: dim)
                    for turn in speakerTurns {
                        for i in 0..<dim { mean[i] += turn.embedding[i] }
                    }
                    mean = mean.map { $0 / Float(speakerTurns.count) }
                    clusterByLocalID[localID] = registry.register(embedding: mean, duration: duration, source: source)
                }
            }

            for segment in segments {
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, text != "[BLANK_AUDIO]" else { continue }
                let t0 = Double(segment.fromMS) / 1000
                let t1 = Double(segment.toMS) / 1000
                let cluster = bestTurn(turns, from: t0, to: t1).flatMap { clusterByLocalID[$0.localSpeakerID] }
                let time = chunkStart.addingTimeInterval(t0)
                raw.append(RawLine(
                    time: time,
                    source: source,
                    app: appName(at: time, metadata: metadata),
                    text: text,
                    cluster: cluster
                ))
            }
        }

        guard readableFiles > 0 else {
            throw VaqloError(L("err.audioCorrupt"))
        }

        // Имена кластерам: библиотека голосов → «я» → «Спикер N».
        let selfLabel = TranscriptGrouper.selfLabel
        var labels = registry.assignLabels(selfLabel: selfLabel)

        // Поверх диаризации — реальные имена из приложения встречи (Slack/Zoom):
        // для каждого кластера берём доминирующее имя активного спикера за его реплики
        // и привязываем голосовой отпечаток к этому имени.
        if let speakers = metadata?.activeSpeakers, !speakers.isEmpty {
            func activeName(at time: Date) -> String? {
                speakers.last { $0.time <= time.addingTimeInterval(0.5) }?.name
            }
            var votes: [String: [String: Int]] = [:]   // cluster → name → count
            for r in raw where r.source == "sys" {
                guard let cluster = r.cluster, let name = activeName(at: r.time) else { continue }
                votes[cluster, default: [:]][name, default: 0] += 1
            }
            let meanByCluster = Dictionary(uniqueKeysWithValues: registry.clusters.map { ($0.key, $0.mean) })
            for (cluster, tally) in votes {
                guard let winner = tally.max(by: { $0.value < $1.value })?.key else { continue }
                labels[cluster] = winner
                if let mean = meanByCluster[cluster] {
                    VoiceLibrary.enroll(name: winner, embedding: mean)
                }
            }
        }

        var lines = raw.map { r -> TranscriptLine in
            let speaker = r.cluster.flatMap { labels[$0] } ?? (r.source == "mic" ? selfLabel : nil)
            return TranscriptLine(
                time: r.time,
                source: r.source,
                label: speaker ?? (r.source == "mic" ? selfLabel : L("speaker.computer")),
                app: r.app,
                speaker: speaker,
                text: r.text
            )
        }
        lines.sort { $0.time < $1.time }
        lines = TranscriptCleaner.clean(lines)

        try write(lines: lines)

        let speakers = registry.clusters.map {
            SessionSpeaker(key: $0.key, label: labels[$0.key] ?? $0.key, embedding: $0.mean, duration: $0.totalDuration)
        }
        SessionSpeaker.save(speakers, for: session)

        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM HH:mm"
        TrashKeeper.trashAudio(audio, sessionTitle: formatter.string(from: session.start))
    }

    /// Реплика Whisper приписывается спикеру с максимальным пересечением по времени.
    private func bestTurn(_ turns: [DiarizationService.Turn], from t0: Double, to t1: Double) -> DiarizationService.Turn? {
        var best: DiarizationService.Turn?
        var bestOverlap = 0.0
        for turn in turns {
            let overlap = min(t1, turn.end) - max(t0, turn.start)
            if overlap > bestOverlap {
                bestOverlap = overlap
                best = turn
            }
        }
        return best
    }

    private func chunkStartDate(name: String, metadata: SessionMetadata?) -> Date? {
        guard let metadata else { return session.start }
        let chunks = name.hasPrefix("mic") ? metadata.micChunks : metadata.systemChunks
        return chunks.first { $0.file == "\(name).m4a" }?.start ?? session.start
    }

    private func appName(at time: Date, metadata: SessionMetadata?) -> String? {
        guard let samples = metadata?.frontmostApps, !samples.isEmpty else { return nil }
        return samples.last { $0.time <= time }?.name ?? samples.first?.name
    }

    // MARK: - whisper-cli

    private func transcribeWav(_ wav: URL, tmpDir: URL) throws -> [WhisperSegment] {
        guard let cli = Bundle.main.url(forResource: "whisper-cli", withExtension: nil) else {
            throw VaqloError("whisper-cli not found inside the app — rebuild it")
        }
        let outPrefix = tmpDir.appendingPathComponent("out")
        let language = UserDefaults.standard.string(forKey: SettingsKeys.language) ?? "auto"
        var arguments = [
            "-m", modelFile.path,
            "-f", wav.path,
            "-l", language,
            "-oj", "-of", outPrefix.path,
            "-np",
        ]
        // VAD отрезает тишину — исчезают галлюцинации вида «Thank you» на пустых местах.
        if let vad = Self.ensureVADModel() {
            arguments += ["--vad", "--vad-model", vad.path]
        }
        try runProcess(cli.path, arguments)

        let data = try Data(contentsOf: outPrefix.appendingPathExtension("json"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let transcription = json?["transcription"] as? [[String: Any]] ?? []
        return transcription.compactMap { item in
            guard let offsets = item["offsets"] as? [String: Any],
                  let from = offsets["from"] as? Int,
                  let to = offsets["to"] as? Int,
                  let text = item["text"] as? String else { return nil }
            return WhisperSegment(fromMS: from, toMS: to, text: text)
        }
    }

    /// Маленькая (~1 МБ) VAD-модель silero: скачивается один раз, лежит рядом с моделями Whisper.
    static func ensureVADModel() -> URL? {
        let url = Storage.models.appendingPathComponent("ggml-silero-v5.1.2.bin")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let remote = URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin")!
        do {
            let data = try Data(contentsOf: remote)
            try data.write(to: url)
            return url
        } catch {
            NSLog("VAD model download failed (продолжаем без VAD): \(error)")
            return nil
        }
    }

    private func runProcess(_ launchPath: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let tool = (launchPath as NSString).lastPathComponent
            throw VaqloError("\(tool) exited with code \(process.terminationStatus): \(err.suffix(300))")
        }
    }

    // MARK: - Вывод

    private func write(lines: [TranscriptLine]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(lines).write(to: session.transcriptJSON)
        try Self.markdown(for: session, lines: lines).data(using: .utf8)!.write(to: session.transcriptMD)
    }

    static func markdown(for session: Session, lines: [TranscriptLine]) -> String {
        Transcriber.markdown(for: session, lines: lines)
    }
}

extension Transcriber {
    /// Используется и транскрайбером, и переименованием спикеров.
    nonisolated static func markdown(for session: Session, lines: [TranscriptLine]) -> String {
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        let time = DateFormatter()
        time.dateFormat = "HH:mm"
        let timeS = DateFormatter()
        timeS.dateFormat = "HH:mm:ss"

        var md = "# \(L("md.recording")) \(day.string(from: session.start)) \(time.string(from: session.start))"
        if let end = session.end { md += "–\(time.string(from: end))" }
        md += "\n\n"
        if lines.isEmpty {
            md += "_\(L("transcript.empty"))_\n"
        }
        for group in TranscriptGrouper.group(lines) {
            md += "**\(timeS.string(from: group.start)) · \(group.label)**"
            if let app = group.app {
                md += " _(\(L("focus.prefix", app)))_"
            }
            md += "\n\n"
            md += group.lines.map(\.text).joined(separator: " ")
            md += "\n\n"
        }
        return md
    }
}
