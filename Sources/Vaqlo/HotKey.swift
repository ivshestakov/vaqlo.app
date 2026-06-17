import AppKit
import Carbon.HIToolbox
import Foundation

// kVK_ANSI_R из Carbon, продублирован, чтобы не тянуть устаревшие заголовки в другие файлы.
let kVK_ANSI_R_Code = 0x0F

/// Глобальная горячая клавиша через Carbon RegisterEventHotKey —
/// единственный системный API, не требующий разрешения Accessibility.
final class HotKey {
    static let cmdOption = UInt32(cmdKey | optionKey)

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let callback: () -> Void

    init?(keyCode: UInt32, modifiers: UInt32, callback: @escaping () -> Void) {
        self.callback = callback

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue().callback()
                return noErr
            },
            1, &eventType, selfPtr, &handlerRef
        )
        guard installStatus == noErr else { return nil }

        let hotKeyID = EventHotKeyID(signature: OSType(0x56_51_4C_4F) /* 'VQLO' */, id: 1)
        let registerStatus = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard registerStatus == noErr else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}

// MARK: - Конвертация и отображение сочетаний

enum HotKeyFormat {
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        return result
    }

    static func description(keyCode: UInt32, modifiers: UInt32) -> String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + keyName(keyCode)
    }

    static func keyName(_ keyCode: UInt32) -> String {
        let names: [UInt32: String] = [
            0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G", 0x06: "Z",
            0x07: "X", 0x08: "C", 0x09: "V", 0x0B: "B", 0x0C: "Q", 0x0D: "W", 0x0E: "E",
            0x0F: "R", 0x10: "Y", 0x11: "T", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4",
            0x16: "6", 0x17: "5", 0x19: "9", 0x1A: "7", 0x1C: "8", 0x1D: "0",
            0x1F: "O", 0x20: "U", 0x22: "I", 0x23: "P", 0x25: "L", 0x26: "J", 0x28: "K",
            0x2D: "N", 0x2E: "M", 0x31: "Space", 0x24: "↩", 0x30: "⇥", 0x33: "⌫", 0x35: "⎋",
            0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6",
            0x62: "F7", 0x64: "F8", 0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12",
            0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑",
        ]
        return names[keyCode] ?? "key\(keyCode)"
    }
}
