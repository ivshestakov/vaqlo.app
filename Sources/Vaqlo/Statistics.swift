import Foundation

/// Сводка по архиву и занятому месту.
struct VaqloStats {
    var sessionCount = 0
    var doneCount = 0
    var pendingCount = 0
    var totalRecordedSeconds: Double = 0
    var hoursThisWeek: Double = 0

    var audioBytes: Int64 = 0      // активное аудио (необработанные сессии)
    var trashBytes: Int64 = 0      // аудио в Корзине
    var modelBytes: Int64 = 0      // Whisper + LLM модели
    var diarizationBytes: Int64 = 0 // CoreML модели FluidAudio
    var transcriptBytes: Int64 = 0 // транскрипты + саммари + метаданные

    var totalBytes: Int64 { audioBytes + trashBytes + modelBytes + diarizationBytes + transcriptBytes }

    @MainActor
    static func compute(library: SessionLibrary) -> VaqloStats {
        var stats = VaqloStats()
        let cal = Calendar.current
        let weekStart = cal.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()

        for session in library.sessions {
            stats.sessionCount += 1
            if session.state == .done { stats.doneCount += 1 }
            if session.state == .pending { stats.pendingCount += 1 }
            let duration = session.duration
            stats.totalRecordedSeconds += duration
            if session.start >= weekStart { stats.hoursThisWeek += duration / 3600 }
        }

        let fm = FileManager.default
        // Аудио и транскрипты внутри recordings/
        for case let url as URL in fm.enumerator(at: Storage.recordings, includingPropertiesForKeys: [.fileSizeKey]) ?? .init() {
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            if url.pathExtension == "m4a" {
                stats.audioBytes += size
            } else {
                stats.transcriptBytes += size
            }
        }

        // Модели Whisper/LLM (.bin/.gguf) + всё в models/
        for case let url as URL in fm.enumerator(at: Storage.models, includingPropertiesForKeys: [.fileSizeKey]) ?? .init() {
            stats.modelBytes += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }

        // CoreML-модели диаризации (FluidAudio) — в общем Application Support
        let diarDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models")
        for case let url as URL in fm.enumerator(at: diarDir, includingPropertiesForKeys: [.fileSizeKey]) ?? .init() {
            stats.diarizationBytes += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }

        // Аудио в Корзине, помеченное нами
        for entry in TrashKeeper.all() {
            let size = directorySize(URL(fileURLWithPath: entry.trashedPath))
            stats.trashBytes += size
        }

        return stats
    }

    private static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        var total: Int64 = 0
        for case let child as URL in fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) ?? .init() {
            total += Int64((try? child.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}

extension Int64 {
    var humanSize: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
