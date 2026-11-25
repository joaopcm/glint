import AppKit
import Carbon.HIToolbox
import KeyboardShortcuts

enum ShortcutKeyPress: Equatable {
    case cancel
    case clear
    case record(KeyboardShortcuts.Shortcut)
    case reject(String)

    private static let chordModifiers: NSEvent.ModifierFlags = [.control, .option, .command]
    private static let functionKeys: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]
    private static let keypadNames: [Int: String] = [
        kVK_ANSI_Keypad0: "0", kVK_ANSI_Keypad1: "1", kVK_ANSI_Keypad2: "2", kVK_ANSI_Keypad3: "3",
        kVK_ANSI_Keypad4: "4", kVK_ANSI_Keypad5: "5", kVK_ANSI_Keypad6: "6", kVK_ANSI_Keypad7: "7",
        kVK_ANSI_Keypad8: "8", kVK_ANSI_Keypad9: "9", kVK_ANSI_KeypadDecimal: ".", kVK_ANSI_KeypadDivide: "/",
        kVK_ANSI_KeypadMultiply: "*", kVK_ANSI_KeypadMinus: "-", kVK_ANSI_KeypadPlus: "+",
        kVK_ANSI_KeypadEquals: "=", kVK_ANSI_KeypadEnter: "Enter", kVK_ANSI_KeypadClear: "Clear",
    ]

    @MainActor static func interpret(
        keyCode: Int,
        modifierFlags: NSEvent.ModifierFlags,
        usedBy owner: (KeyboardShortcuts.Shortcut) -> String?
    ) -> ShortcutKeyPress {
        let modifiers = modifierFlags.intersection([.control, .option, .shift, .command])
        if modifiers.isEmpty {
            switch keyCode {
            case kVK_Escape, kVK_Tab: return .cancel
            case kVK_Delete, kVK_ForwardDelete: return .clear
            default: break
            }
        }
        let shortcut = KeyboardShortcuts.Shortcut(carbonKeyCode: keyCode, carbonModifiers: carbon(modifiers))
        if modifiers.isDisjoint(with: chordModifiers), !functionKeys.contains(keyCode) {
            return .reject("\(label(shortcut)) would fire while you type. Add ⌃, ⌥ or ⌘.")
        }
        if let owner = owner(shortcut) {
            return .reject("\(label(shortcut)) is already the \(owner) shortcut.")
        }
        return .record(shortcut)
    }

    @MainActor static func label(_ shortcut: KeyboardShortcuts.Shortcut) -> String {
        guard let keypad = keypadNames[shortcut.carbonKeyCode] else { return "\(shortcut)" }
        return [shortcut.modifiers.ks_symbolicRepresentation, "Num \(keypad)"].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func carbon(_ modifiers: NSEvent.ModifierFlags) -> Int {
        var carbon = 0
        if modifiers.contains(.control) { carbon |= controlKey }
        if modifiers.contains(.option) { carbon |= optionKey }
        if modifiers.contains(.shift) { carbon |= shiftKey }
        if modifiers.contains(.command) { carbon |= cmdKey }
        return carbon
    }
}
