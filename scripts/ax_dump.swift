import AppKit
import ApplicationServices

// Диагностика: дампит дерево Accessibility указанного приложения, чтобы найти,
// где Slack/Zoom хранят имя активного спикера.
//
// Запуск (нужно разрешение «Универсальный доступ» для Терминала):
//   swiftc scripts/ax_dump.swift -o /tmp/ax_dump
//   /tmp/ax_dump com.tinyspeck.slackmacgap > slack_ax.txt
// По умолчанию bundle id = Slack. Можно передать любой (us.zoom.xos и т.д.).

let bundleID = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "com.tinyspeck.slackmacgap"

guard AXIsProcessTrusted() else {
    fputs("Нет доступа Accessibility. Системные настройки → Конфиденциальность → Универсальный доступ → добавьте Терминал.\n", stderr)
    exit(2)
}
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
    fputs("Приложение \(bundleID) не запущено.\n", stderr)
    exit(1)
}

let axApp = AXUIElementCreateApplication(app.processIdentifier)

func attr(_ el: AXUIElement, _ key: String) -> Any? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, key as CFString, &value) == .success ? value : nil
}
func str(_ el: AXUIElement, _ key: String) -> String? {
    (attr(el, key) as? String).flatMap { $0.isEmpty ? nil : $0 }
}
func children(_ el: AXUIElement) -> [AXUIElement] {
    (attr(el, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}

var lines = 0
func walk(_ el: AXUIElement, depth: Int) {
    if lines > 4000 { return }
    let role = str(el, kAXRoleAttribute as String) ?? "?"
    let subrole = str(el, kAXSubroleAttribute as String)
    let title = str(el, kAXTitleAttribute as String)
    let value = attr(el, kAXValueAttribute as String) as? String
    let desc = str(el, kAXDescriptionAttribute as String)
    let help = str(el, kAXHelpAttribute as String)
    let ident = str(el, "AXIdentifier")
    let selected = attr(el, kAXSelectedAttribute as String) as? Bool

    // Печатаем только узлы с текстовой/именной нагрузкой — чтобы дамп был читаемым.
    var parts: [String] = []
    if let title { parts.append("title=\(title)") }
    if let value { parts.append("value=\(value)") }
    if let desc { parts.append("desc=\(desc)") }
    if let help { parts.append("help=\(help)") }
    if let ident { parts.append("id=\(ident)") }
    if let selected, selected { parts.append("SELECTED") }
    if !parts.isEmpty {
        let pad = String(repeating: "  ", count: depth)
        let sr = subrole.map { " (\($0))" } ?? ""
        print("\(pad)[\(role)\(sr)] \(parts.joined(separator: " | "))")
        lines += 1
    }
    for child in children(el) { walk(child, depth: depth + 1) }
}

print("=== AX dump: \(bundleID) (pid \(app.processIdentifier)) ===")
walk(axApp, depth: 0)
print("=== конец (\(lines) узлов с текстом) ===")
