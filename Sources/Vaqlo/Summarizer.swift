import Foundation

/// Саммаризация транскрипта локальной LLM через встроенный llama-cli.
/// Результат — summary.md рядом с транскриптом.
@MainActor
final class Summarizer: ObservableObject {
    @Published private(set) var workingIDs: Set<String> = []
    @Published var lastError: String?

    private let models: ModelManager

    init(models: ModelManager) {
        self.models = models
    }

    nonisolated static func summaryURL(for session: Session) -> URL {
        session.directory.appendingPathComponent("summary.md")
    }

    func summarize(_ session: Session) {
        guard !workingIDs.contains(session.id) else { return }
        guard let modelFile = models.readySummaryModelFile else {
            lastError = L("err.summaryModel")
            return
        }
        guard let data = try? Data(contentsOf: session.transcriptJSON) else {
            lastError = L("err.transcribeFirst")
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let lines = try? decoder.decode([TranscriptLine].self, from: data), !lines.isEmpty else {
            lastError = L("err.noTextForSummary")
            return
        }

        workingIDs.insert(session.id)
        lastError = nil
        let strings = LocalizationManager.shared.summary

        Task.detached(priority: .utility) {
            let result: Result<String, Error>
            do {
                let summary = try SummaryJob(modelFile: modelFile, s: strings).run(lines: lines)
                try summary.data(using: .utf8)?.write(to: Self.summaryURL(for: session))
                result = .success(summary)
            } catch {
                result = .failure(error)
            }
            await MainActor.run {
                if case .failure(let error) = result {
                    self.lastError = "\(L("summary.title")) · \(session.id): \(error.localizedDescription)"
                }
                self.workingIDs.remove(session.id)
                AppStore.shared.transcriptRevision += 1
            }
        }
    }
}

/// Синхронная работа над одним саммари, выполняется вне главного потока.
private struct SummaryJob {
    let modelFile: URL
    let s: SummaryStrings

    /// Транскрипты длиннее лимита саммаризируются по кускам, потом сводятся.
    private let chunkLimit = 20_000

    func run(lines: [TranscriptLine]) throws -> String {
        let text = TranscriptGrouper.group(lines).map { group in
            "\(group.label): \(group.lines.map(\.text).joined(separator: " "))"
        }.joined(separator: "\n")

        if text.count <= chunkLimit {
            return try summarizeChunk(text, final: true)
        }

        var partials: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: chunkLimit, limitedBy: text.endIndex) ?? text.endIndex
            partials.append(try summarizeChunk(String(text[start..<end]), final: false))
            start = end
        }
        return try summarizeChunk(partials.joined(separator: "\n\n"), final: true)
    }

    private func summarizeChunk(_ text: String, final: Bool) throws -> String {
        let system = s.system
        let prompt: String
        if final {
            prompt = """
            \(s.intro)

            ## \(s.tldr)
            \(s.tldrHint)

            ## \(s.decisions)
            \(s.decisionsHint)

            ## \(s.actions)
            \(s.actionsHint)

            \(s.transcriptLabel)
            \(text)
            """
        } else {
            prompt = "\(s.condense)\n\n\(text)"
        }

        guard let cli = Bundle.main.url(forResource: "llama-completion", withExtension: nil) else {
            throw VaqloError("llama-completion not found inside the app — rebuild it")
        }

        let process = Process()
        process.executableURL = cli
        process.arguments = [
            "-m", modelFile.path,
            "--jinja",
            "-sys", system,
            "-p", prompt,
            "-n", "1024",
            "--temp", "0.2",
            "-c", "16384",
            "--no-display-prompt",
            "--no-warmup",
        ]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw VaqloError("llama-cli exited with code \(process.terminationStatus): \(message.suffix(300))")
        }
        let result = String(data: data, encoding: .utf8)?
            .replacingOccurrences(of: "[end of text]", with: "")
            .replacingOccurrences(of: "> EOF by user", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !result.isEmpty else { throw VaqloError("The model returned an empty response") }
        return result
    }
}
