import Foundation

/// Полнотекстовый поиск по всем транскриптам и саммари.
enum TranscriptSearch {
    struct Result: Identifiable {
        let sessionID: String
        let start: Date
        let snippet: String
        let matchCount: Int
        var id: String { sessionID }
    }

    static func search(_ rawQuery: String, in sessions: [Session]) -> [Result] {
        let query = rawQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard query.count >= 2 else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var results: [Result] = []
        for session in sessions where session.state == .done {
            guard let data = try? Data(contentsOf: session.transcriptJSON),
                  let lines = try? decoder.decode([TranscriptLine].self, from: data) else { continue }

            let matches = lines.filter { $0.text.lowercased().contains(query) }
            guard !matches.isEmpty else { continue }

            let snippet = makeSnippet(matches.first!.text, query: query)
            results.append(Result(
                sessionID: session.id,
                start: session.start,
                snippet: snippet,
                matchCount: matches.count
            ))
        }
        return results.sorted { $0.start > $1.start }
    }

    /// Кусок текста вокруг первого совпадения.
    private static func makeSnippet(_ text: String, query: String) -> String {
        let lower = text.lowercased()
        guard let range = lower.range(of: query) else { return String(text.prefix(120)) }
        let start = text.index(range.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 80, limitedBy: text.endIndex) ?? text.endIndex
        var snippet = String(text[start..<end])
        if start > text.startIndex { snippet = "…" + snippet }
        if end < text.endIndex { snippet += "…" }
        return snippet
    }
}
