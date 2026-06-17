import AppKit
import ApplicationServices
import Foundation

/// Одна точка таймлайна «кто говорит».
struct ActiveSpeakerSample: Codable {
    let time: Date
    let name: String
}

/// Разрешение Accessibility — нужно, чтобы читать UI приложения встречи.
enum AccessibilityHelper {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Показывает системный запрос (если ещё не выдан).
    static func prompt() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}

/// Утилиты обхода AX-дерева.
enum AX {
    static func attr(_ el: AXUIElement, _ key: String) -> Any? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, key as CFString, &value) == .success ? value : nil
    }
    static func string(_ el: AXUIElement, _ key: String) -> String? {
        (attr(el, key) as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
    static func children(_ el: AXUIElement) -> [AXUIElement] {
        (attr(el, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
    }
}

/// Извлекает имя активного спикера из приложения встречи. Один экстрактор на приложение.
protocol SpeakerExtractor {
    /// bundle id приложения, которое умеет обрабатывать.
    static var bundleID: String { get }
    /// Имя того, кто говорит прямо сейчас (или nil, если не определилось).
    func activeSpeaker(app: AXUIElement) -> String?
}

/// Slack huddle. Электрон-приложение; «говорит сейчас» Slack помечает в AX —
/// точные атрибуты подбираются по дампу `scripts/ax_dump.swift` на живом хадле.
struct SlackSpeakerExtractor: SpeakerExtractor {
    static let bundleID = "com.tinyspeck.slackmacgap"

    func activeSpeaker(app: AXUIElement) -> String? {
        // Эвристика 1: где-то в дереве есть текст вида "<Имя> is speaking" /
        // "<Имя> говорит" — в description/help/title/value.
        if let name = search(app, depth: 0) { return name }
        return nil
    }

    private func search(_ el: AXUIElement, depth: Int) -> String? {
        if depth > 40 { return nil }
        for key in [kAXDescriptionAttribute as String, kAXHelpAttribute as String,
                    kAXTitleAttribute as String, kAXValueAttribute as String] {
            if let text = AX.string(el, key), let name = Self.speakingName(from: text) {
                return name
            }
        }
        for child in AX.children(el) {
            if let found = search(child, depth: depth + 1) { return found }
        }
        return nil
    }

    /// Вытаскивает имя из строки-индикатора речи на нескольких языках.
    static func speakingName(from text: String) -> String? {
        let patterns = [
            #"^(.+?)\s+is speaking$"#,
            #"^(.+?)\s+говорит$"#,
            #"^(.+?)\s+parle$"#,
            #"^(.+?)\s+está hablando$"#,
            #"^(.+?)\s+spricht$"#,
        ]
        for p in patterns {
            if let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]),
               let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let r = Range(m.range(at: 1), in: text) {
                let name = String(text[r]).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { return name }
            }
        }
        return nil
    }
}

/// Сэмплирует активного спикера приложения встречи раз в ~1.5 c; точку пишет только при смене.
/// Таймер и AX-вызовы живут на главном потоке (как FrontmostAppSampler).
final class ActiveSpeakerSampler {
    private let extractors: [SpeakerExtractor] = [SlackSpeakerExtractor()]
    private var timer: Timer?
    private var samples: [ActiveSpeakerSample] = []

    func start() {
        samples = []
        guard AccessibilityHelper.isTrusted,
              UserDefaults.standard.bool(forKey: SettingsKeys.detectSpeakerNames) else { return }
        record()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.record()
        }
    }

    func stop() -> [ActiveSpeakerSample] {
        timer?.invalidate()
        timer = nil
        return samples
    }

    var snapshot: [ActiveSpeakerSample] { samples }

    private func record() {
        guard let name = currentSpeaker() else { return }
        if samples.last?.name != name {
            samples.append(ActiveSpeakerSample(time: Date(), name: name))
        }
    }

    private func currentSpeaker() -> String? {
        for extractor in extractors {
            guard let app = NSRunningApplication.runningApplications(
                withBundleIdentifier: type(of: extractor).bundleID).first else { continue }
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            if let name = extractor.activeSpeaker(app: axApp) { return name }
        }
        return nil
    }
}
