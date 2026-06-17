import FluidAudio
import Foundation

/// Обёртка над FluidAudio: «кто когда говорил» + голосовой отпечаток каждого спикера.
/// CoreML-модели (~50 МБ) скачиваются сами при первой транскрибации.
final class DiarizationService {
    struct Turn {
        let localSpeakerID: String   // id спикера внутри одного файла
        let start: Double            // секунды от начала файла
        let end: Double
        let embedding: [Float]
    }

    private let manager: DiarizerManager

    private init(manager: DiarizerManager) {
        self.manager = manager
    }

    static func make() async -> DiarizationService? {
        do {
            let models = try await DiarizerModels.downloadIfNeeded()
            let manager = DiarizerManager()
            manager.initialize(models: models)
            return DiarizationService(manager: manager)
        } catch {
            NSLog("Diarization недоступна (продолжаем без разделения голосов): \(error)")
            return nil
        }
    }

    func diarize(wav: URL) -> [Turn] {
        do {
            let samples = try AudioConverter().resampleAudioFile(wav)
            let result = try manager.performCompleteDiarization(samples)
            return result.segments.map {
                Turn(
                    localSpeakerID: $0.speakerId,
                    start: Double($0.startTimeSeconds),
                    end: Double($0.endTimeSeconds),
                    embedding: $0.embedding
                )
            }
        } catch {
            NSLog("Diarization файла не удалась: \(error)")
            return []
        }
    }
}

func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    var dot: Float = 0, na: Float = 0, nb: Float = 0
    for i in 0..<a.count {
        dot += a[i] * b[i]
        na += a[i] * a[i]
        nb += b[i] * b[i]
    }
    let denom = (na.squareRoot() * nb.squareRoot())
    return denom > 0 ? dot / denom : 0
}

// MARK: - Кластеры спикеров внутри сессии

/// Сводит спикеров из разных файлов (mic/sys, чанки) в единых людей по близости отпечатков.
final class SpeakerRegistry {
    struct Cluster {
        let key: String
        var embeddingSum: [Float]
        var count: Int
        var durationBySource: [String: Double]

        var mean: [Float] { embeddingSum.map { $0 / Float(count) } }
        var totalDuration: Double { durationBySource.values.reduce(0, +) }
    }

    private(set) var clusters: [Cluster] = []
    private let mergeThreshold: Float = 0.8

    /// Регистрирует спикера (средний отпечаток одного файла) и возвращает ключ кластера.
    func register(embedding: [Float], duration: Double, source: String) -> String {
        var bestIndex = -1
        var bestScore: Float = 0
        for (index, cluster) in clusters.enumerated() {
            let score = cosineSimilarity(cluster.mean, embedding)
            if score > bestScore {
                bestScore = score
                bestIndex = index
            }
        }
        if bestIndex >= 0, bestScore >= mergeThreshold {
            for i in 0..<embedding.count {
                clusters[bestIndex].embeddingSum[i] += embedding[i]
            }
            clusters[bestIndex].count += 1
            clusters[bestIndex].durationBySource[source, default: 0] += duration
            return clusters[bestIndex].key
        }
        let key = "c\(clusters.count + 1)"
        clusters.append(Cluster(
            key: key,
            embeddingSum: embedding,
            count: 1,
            durationBySource: [source: duration]
        ))
        return key
    }

    /// Раздаёт кластерам имена: библиотека голосов → «я» (доминирующий на микрофоне) → «Спикер N».
    func assignLabels(selfLabel: String) -> [String: String] {
        var labels: [String: String] = [:]
        let micDominantKey = clusters
            .max { ($0.durationBySource["mic"] ?? 0) < ($1.durationBySource["mic"] ?? 0) }
            .flatMap { ($0.durationBySource["mic"] ?? 0) > 3 ? $0.key : nil }

        var speakerNumber = 1
        for cluster in clusters.sorted(by: { $0.totalDuration > $1.totalDuration }) {
            if let match = VoiceLibrary.bestMatch(cluster.mean) {
                if match.score >= 0.65 {
                    labels[cluster.key] = match.name
                    VoiceLibrary.enroll(name: match.name, embedding: cluster.mean)
                    continue
                }
                if match.score >= 0.5, cluster.key != micDominantKey {
                    labels[cluster.key] = "\(match.name)?"
                    continue
                }
            }
            if cluster.key == micDominantKey {
                labels[cluster.key] = selfLabel
                VoiceLibrary.enroll(name: selfLabel, embedding: cluster.mean, isSelf: true)
                continue
            }
            labels[cluster.key] = L("speaker.n", speakerNumber)
            speakerNumber += 1
        }
        return labels
    }
}

// MARK: - Спикеры сессии (speakers.json) и библиотека голосов (voices.json)

/// Отпечатки спикеров конкретной сессии — чтобы потом можно было переименовать
/// «Спикер 1» в «Иван» и запомнить голос.
struct SessionSpeaker: Codable {
    let key: String
    var label: String
    let embedding: [Float]
    let duration: Double

    static func fileURL(for session: Session) -> URL {
        session.directory.appendingPathComponent("speakers.json")
    }

    static func load(for session: Session) -> [SessionSpeaker] {
        guard let data = try? Data(contentsOf: fileURL(for: session)) else { return [] }
        return (try? JSONDecoder().decode([SessionSpeaker].self, from: data)) ?? []
    }

    static func save(_ speakers: [SessionSpeaker], for session: Session) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(speakers).write(to: fileURL(for: session))
    }
}

/// Локальная библиотека известных голосов: имя + усреднённый отпечаток.
enum VoiceLibrary {
    struct Entry: Codable {
        var name: String
        var embedding: [Float]
        var samples: Int
        var isSelf: Bool?
    }

    private static var url: URL { Storage.root.appendingPathComponent("voices.json") }

    static func load() -> [Entry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    private static func save(_ entries: [Entry]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try? encoder.encode(entries).write(to: url)
    }

    static func remove(name: String) {
        save(load().filter { $0.name != name })
    }

    static func rename(from oldName: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != oldName else { return }
        var entries = load()
        guard let index = entries.firstIndex(where: { $0.name == oldName }) else { return }
        // Если имя занято — сливаем отпечатки.
        if let target = entries.firstIndex(where: { $0.name == trimmed }) {
            let a = entries[target], b = entries[index]
            let total = Float(a.samples + b.samples)
            var merged = a.embedding
            for i in 0..<min(merged.count, b.embedding.count) {
                merged[i] = (a.embedding[i] * Float(a.samples) + b.embedding[i] * Float(b.samples)) / total
            }
            entries[target].embedding = merged
            entries[target].samples += b.samples
            entries.remove(at: index)
        } else {
            entries[index].name = trimmed
        }
        save(entries)
    }

    static func bestMatch(_ embedding: [Float]) -> (name: String, score: Float)? {
        var best: (String, Float)?
        for entry in load() {
            let score = cosineSimilarity(entry.embedding, embedding)
            if score > (best?.1 ?? 0) {
                best = (entry.name, score)
            }
        }
        return best
    }

    /// Добавляет/обновляет голос: отпечаток усредняется с уже накопленным.
    static func enroll(name: String, embedding: [Float], isSelf: Bool = false) {
        var entries = load()
        if let index = entries.firstIndex(where: { $0.name == name }) {
            let old = entries[index]
            let total = Float(old.samples + 1)
            var merged = old.embedding
            for i in 0..<min(merged.count, embedding.count) {
                merged[i] = (merged[i] * Float(old.samples) + embedding[i]) / total
            }
            entries[index].embedding = merged
            entries[index].samples += 1
        } else {
            entries.append(Entry(name: name, embedding: embedding, samples: 1, isSelf: isSelf ? true : nil))
        }
        save(entries)
    }
}
