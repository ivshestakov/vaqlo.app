import Foundation

/// Любая скачиваемая модель (Whisper, LLM для саммари).
protocol DownloadableModel: Identifiable {
    var id: String { get }
    var title: String { get }
    var details: String { get }
    var sizeMB: Int { get }
    var url: URL { get }
    var fileURL: URL { get }
}

struct WhisperModel: DownloadableModel {
    let id: String          // имя пресета и базовое имя файла
    let title: String
    let details: String
    let sizeMB: Int
    let url: URL

    var fileURL: URL { Storage.models.appendingPathComponent("ggml-\(id).bin") }

    static var presets: [WhisperModel] { [
        WhisperModel(
            id: "large-v3-turbo-q5_0",
            title: "Large v3 Turbo (\(L("model.recommended")))",
            details: L("model.whisper.turbo"),
            sizeMB: 574,
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin")!
        ),
        WhisperModel(
            id: "small-q5_1",
            title: "Small",
            details: L("model.whisper.small"),
            sizeMB: 190,
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small-q5_1.bin")!
        ),
        WhisperModel(
            id: "base-q5_1",
            title: "Base",
            details: L("model.whisper.base"),
            sizeMB: 60,
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base-q5_1.bin")!
        ),
    ] }
}

/// LLM для саммаризации (GGUF, запускается встроенным llama-cli).
struct SummaryModel: DownloadableModel {
    let id: String
    let title: String
    let details: String
    let sizeMB: Int
    let url: URL

    var fileURL: URL { Storage.models.appendingPathComponent("\(id).gguf") }

    static var presets: [SummaryModel] { [
        SummaryModel(
            id: "qwen3-4b-instruct-q4",
            title: "Qwen3 4B (\(L("model.recommended")))",
            details: L("model.llm.qwen"),
            sizeMB: 2400,
            url: URL(string: "https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen3-4B-Instruct-2507-Q4_K_M.gguf")!
        ),
        SummaryModel(
            id: "llama-3.2-3b-instruct-q4",
            title: "Llama 3.2 3B",
            details: L("model.llm.llama3b"),
            sizeMB: 1950,
            url: URL(string: "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf")!
        ),
        SummaryModel(
            id: "llama-3.2-1b-instruct-q4",
            title: "Llama 3.2 1B",
            details: L("model.llm.llama1b"),
            sizeMB: 810,
            url: URL(string: "https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf")!
        ),
    ] }
}

/// Скачивание моделей (Whisper + LLM) внутрь приложения, с прогрессом.
@MainActor
final class ModelManager: NSObject, ObservableObject {
    @Published var progress: [String: Double] = [:]   // model id → 0…1
    @Published var errors: [String: String] = [:]
    @Published private(set) var downloadedIDs: Set<String> = []

    private var tasks: [String: URLSessionDownloadTask] = [:]
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    /// Полный каталог скачиваемых моделей.
    nonisolated static var catalog: [any DownloadableModel] {
        WhisperModel.presets + SummaryModel.presets
    }

    override init() {
        super.init()
        refresh()
    }

    func refresh() {
        downloadedIDs = Set(Self.catalog.filter {
            FileManager.default.fileExists(atPath: $0.fileURL.path)
        }.map(\.id))
    }

    var activeModel: WhisperModel? {
        let id = UserDefaults.standard.string(forKey: SettingsKeys.activeModel) ?? ""
        return WhisperModel.presets.first { $0.id == id }
    }

    /// Модель Whisper, готовая к использованию (активная, файл на месте).
    var readyModelFile: URL? {
        guard let model = activeModel, downloadedIDs.contains(model.id) else { return nil }
        return model.fileURL
    }

    /// LLM для саммари, готовая к использованию.
    var readySummaryModelFile: URL? {
        let id = UserDefaults.standard.string(forKey: SettingsKeys.activeSummaryModel) ?? ""
        guard let model = SummaryModel.presets.first(where: { $0.id == id }),
              downloadedIDs.contains(model.id) else { return nil }
        return model.fileURL
    }

    func download(_ model: any DownloadableModel) {
        guard tasks[model.id] == nil else { return }
        errors[model.id] = nil
        progress[model.id] = 0
        let task = session.downloadTask(with: model.url)
        task.taskDescription = model.id
        tasks[model.id] = task
        task.resume()
    }

    func cancelDownload(_ model: any DownloadableModel) {
        tasks[model.id]?.cancel()
        tasks[model.id] = nil
        progress[model.id] = nil
    }

    func delete(_ model: any DownloadableModel) {
        try? FileManager.default.removeItem(at: model.fileURL)
        refresh()
    }
}

extension ModelManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription, totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor in self.progress[id] = fraction }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription,
              let model = Self.catalog.first(where: { $0.id == id }) else { return }
        // location живёт только внутри этого вызова — переносим синхронно.
        var moveError: String?
        do {
            try? FileManager.default.removeItem(at: model.fileURL)
            try FileManager.default.moveItem(at: location, to: model.fileURL)
        } catch {
            moveError = error.localizedDescription
        }
        Task { @MainActor in
            self.tasks[id] = nil
            self.progress[id] = nil
            self.errors[id] = moveError
            self.refresh()
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, (error as NSError).code != NSURLErrorCancelled,
              let id = task.taskDescription else { return }
        Task { @MainActor in
            self.tasks[id] = nil
            self.progress[id] = nil
            self.errors[id] = error.localizedDescription
        }
    }
}
