import CryptoKit
import Foundation

/// Любая скачиваемая модель (Whisper, LLM для саммари).
protocol DownloadableModel: Identifiable {
    var id: String { get }
    var title: String { get }
    var details: String { get }
    var sizeMB: Int { get }
    var url: URL { get }
    var fileURL: URL { get }
    /// SHA-256 и размер файла на закреплённом коммите: скачанное сверяется до установки.
    var sha256: String { get }
    var bytes: Int64 { get }
}

/// Проверка целостности моделей. Ссылки закреплены на коммит репозитория (не `main`),
/// хэш — тот же, что HuggingFace отдаёт в `X-Linked-Etag`. Подменённый или битый файл
/// не попадёт к whisper.cpp / llama.cpp, которые разбирают его с правами пользователя.
enum ModelIntegrity {
    static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 8 << 20)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func verify(_ url: URL, sha256 expected: String, bytes: Int64) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? -1
        guard size == bytes else { return false }
        return sha256(of: url) == expected
    }
}

struct WhisperModel: DownloadableModel {
    let id: String          // имя пресета и базовое имя файла
    let title: String
    let details: String
    let sizeMB: Int
    let url: URL
    let sha256: String
    let bytes: Int64

    var fileURL: URL { Storage.models.appendingPathComponent("ggml-\(id).bin") }

    static var presets: [WhisperModel] { [
        WhisperModel(
            id: "large-v3-turbo-q5_0",
            title: "Large v3 Turbo (\(L("model.recommended")))",
            details: L("model.whisper.turbo"),
            sizeMB: 574,
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo-q5_0.bin")!,
            sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2",
            bytes: 574_041_195
        ),
        WhisperModel(
            id: "small-q5_1",
            title: "Small",
            details: L("model.whisper.small"),
            sizeMB: 190,
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-small-q5_1.bin")!,
            sha256: "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb",
            bytes: 190_085_487
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
    let sha256: String
    let bytes: Int64

    var fileURL: URL { Storage.models.appendingPathComponent("\(id).gguf") }

    static var presets: [SummaryModel] { [
        SummaryModel(
            id: "qwen3-4b-instruct-q4",
            title: "Qwen3 4B (\(L("model.recommended")))",
            details: L("model.llm.qwen"),
            sizeMB: 2400,
            url: URL(string: "https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/a06e946bb6b655725eafa393f4a9745d460374c9/Qwen3-4B-Instruct-2507-Q4_K_M.gguf")!,
            sha256: "3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597",
            bytes: 2_497_281_120
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
        Self.migrateRemovedPresets()
        refresh()
    }

    /// Каталог сокращён до проверенных моделей (0.1.9: убраны Whisper Base и Llama 3.2).
    /// Кто выбрал убранную — переезжает на рекомендуемую, иначе транскрибация/саммари
    /// молча перестали бы находить модель.
    private static func migrateRemovedPresets() {
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: SettingsKeys.activeModel), !WhisperModel.presets.contains(where: { $0.id == id }) {
            defaults.removeObject(forKey: SettingsKeys.activeModel)
        }
        if let id = defaults.string(forKey: SettingsKeys.activeSummaryModel), !SummaryModel.presets.contains(where: { $0.id == id }) {
            defaults.removeObject(forKey: SettingsKeys.activeSummaryModel)
        }
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
        // Страница ошибки (404/5xx) тоже «скачивается» — раньше она ложилась как модель
        // и ломала каждую следующую транскрибацию.
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            Task { @MainActor in
                self.tasks[id] = nil
                self.progress[id] = nil
                self.errors[id] = L("err.modelHTTP", status)
            }
            return
        }
        // location живёт только внутри этого вызова — синхронно уносим во временный файл
        // рядом с моделью, проверяем хэш в фоне и только потом ставим на место.
        let partial = model.fileURL.appendingPathExtension("part")
        var moveError: String?
        do {
            try? FileManager.default.removeItem(at: partial)
            try FileManager.default.moveItem(at: location, to: partial)
        } catch {
            moveError = error.localizedDescription
        }
        let sha256 = model.sha256, bytes = model.bytes, target = model.fileURL
        DispatchQueue.global(qos: .utility).async {
            var error = moveError
            if error == nil {
                if ModelIntegrity.verify(partial, sha256: sha256, bytes: bytes) {
                    do {
                        try? FileManager.default.removeItem(at: target)
                        try FileManager.default.moveItem(at: partial, to: target)
                    } catch let moveFailure {
                        error = moveFailure.localizedDescription
                    }
                } else {
                    error = L("err.modelChecksum")
                }
            }
            try? FileManager.default.removeItem(at: partial)
            Task { @MainActor in
                self.tasks[id] = nil
                self.progress[id] = nil
                self.errors[id] = error
                self.refresh()
            }
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
