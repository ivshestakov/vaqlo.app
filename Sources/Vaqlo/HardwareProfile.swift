import Foundation

/// Что умеет этот Mac — для выбора моделей. Модели живут в общей памяти с системой
/// и встречей (Zoom/Chrome), поэтому порог считается по объёму RAM с запасом.
struct HardwareProfile {
    let memoryGB: Double
    let chip: String
    let appleSilicon: Bool
    /// Свободно на томе с моделями (с учётом того, что macOS может освободить); nil — не удалось узнать.
    let freeDiskGB: Double?

    static func current() -> HardwareProfile {
        HardwareProfile(
            memoryGB: Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824,
            chip: sysctlString("machdep.cpu.brand_string") ?? "Mac",
            appleSilicon: sysctlInt("hw.optional.arm64") == 1,
            freeDiskGB: freeDisk(at: Storage.models)
        )
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer).trimmingCharacters(in: .whitespaces)
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    private static func freeDisk(at url: URL) -> Double? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage.map { Double($0) / 1_000_000_000 }
    }
}

/// Насколько модель подходит этому Mac.
enum ModelFit: Equatable {
    case recommended            // лучшая из тех, что уверенно потянет
    case fits                   // потянет, но есть лучше
    case lowMemory(needGB: Int) // может не хватить памяти
    case noDisk(needGB: Double) // не хватит места для скачивания
}

enum ModelAdvisor {
    /// Лучшая (по `rank`) модель, которой хватает памяти. Если не хватает ни одной — самая лёгкая.
    static func recommended<M: DownloadableModel>(_ presets: [M], for hw: HardwareProfile) -> M? {
        presets.filter { Double($0.minMemoryGB) <= hw.memoryGB + 0.5 }.max { $0.rank < $1.rank }
            ?? presets.min { $0.minMemoryGB < $1.minMemoryGB }
    }

    static func fit<M: DownloadableModel>(_ model: M, among presets: [M], for hw: HardwareProfile, downloaded: Bool) -> ModelFit {
        // Запас 1 ГБ: временный .part лежит рядом, пока сверяется хэш.
        let needGB = Double(model.bytes) / 1_000_000_000 + 1
        if !downloaded, let free = hw.freeDiskGB, free < needGB { return .noDisk(needGB: needGB) }
        if recommended(presets, for: hw)?.id == model.id { return .recommended }
        if Double(model.minMemoryGB) > hw.memoryGB + 0.5 { return .lowMemory(needGB: model.minMemoryGB) }
        return .fits
    }
}
