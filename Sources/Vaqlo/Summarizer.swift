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
        guard let model = models.readySummaryModel else {
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
        let context = session.loadMetadata()?.meeting?.promptContext()

        Task.detached(priority: .utility) {
            let result: Result<String, Error>
            do {
                let summary = try SummaryJob(model: model, s: strings, meetingContext: context).run(lines: lines)
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
    let model: SummaryModel
    let s: SummaryStrings
    /// Название, участники и описание встречи из календаря — только в финальный промпт.
    let meetingContext: String?

    /// Транскрипты длиннее лимита саммаризируются по кускам, потом сводятся.
    private var chunkLimit: Int { model.chunkChars }

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
            \(meetingContext.map { "\n\(s.context)\n\($0)\n" } ?? "")
            \(s.transcriptLabel)
            \(text)
            """
        } else {
            prompt = "\(s.condense)\n\n\(text)"
        }

        guard let cli = Bundle.main.url(forResource: "llama-completion", withExtension: nil) else {
            throw VaqloError("llama-completion not found inside the app — rebuild it")
        }

        var arguments = [
            "-m", model.fileURL.path,
            "--jinja",
            "-st",  // один ход и выход: без этого свежий llama.cpp ждёт диалога и выдаёт пустоту
            "-sys", system,
            "-p", prompt,
            "-n", "1024",
            "--temp", "0.2",
            "-c", String(model.contextTokens),
            "--no-display-prompt",
            "--no-warmup",
        ]
        if let name = model.chatTemplate {
            guard let template = Bundle.main.url(forResource: name, withExtension: "jinja") else {
                throw VaqloError("Chat template \(name).jinja not found inside the app — rebuild it")
            }
            arguments.insert(contentsOf: ["--chat-template-file", template.path], at: 2)
        }
        let output = try ProcessRunner.run(cli, arguments)
        guard output.status == 0 else {
            throw VaqloError("llama-cli exited with code \(output.status): \(output.stderrText.suffix(300))")
        }
        let data = output.stdout
        let result = String(data: data, encoding: .utf8)?
            .replacingOccurrences(of: "[end of text]", with: "")
            .replacingOccurrences(of: "> EOF by user", with: "")
            // Блок «размышлений» (Gemma 4 и др.), если шаблон его всё-таки пропустил.
            .replacingOccurrences(of: #"<\|channel>thought[\s\S]*?(<channel\|>|$)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"<think>[\s\S]*?(</think>|$)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !result.isEmpty else { throw VaqloError("The model returned an empty response") }
        return SummarySanitizer.clean(result)
    }
}

/// Чистит ответ LLM от ссылок, картинок и HTML. В промпт попадает чужой текст
/// (описание приглашения в календаре, речь собеседников) — через него модель можно
/// заставить вставить `![](https://…?d=<кусок транскрипта>)`: SwiftUI делает ссылку
/// кликабельной, а Obsidian подгружает картинку из экспорта — и данные уходят наружу.
enum SummarySanitizer {
    static func clean(_ text: String) -> String {
        var s = text
        let rules: [(String, String)] = [
            (#"!\[([^\]]*)\]\([^)]*\)"#, "$1"),            // ![alt](url) → alt
            (#"\[([^\]]+)\]\([^)]*\)"#, "$1"),             // [text](url) → text
            (#"(?m)^\s*\[[^\]]+\]:\s*\S+.*$"#, ""),        // [ref]: url
            (#"\[([^\]]+)\]\[[^\]]*\]"#, "$1"),           // [text][ref] → text
            (#"<(https?|ftp|file|mailto|data|javascript):[^>]*>"#, ""), // <scheme:…>
            (#"</?[A-Za-z][^>]*>"#, ""),                       // HTML-теги (<img>, <a>, <iframe>)
        ]
        for (pattern, template) in rules {
            s = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return s
    }
}
