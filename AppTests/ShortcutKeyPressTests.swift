import AppKit
import Carbon.HIToolbox
import KeyboardShortcuts
import Testing
@testable import Glint

@MainActor struct ShortcutKeyPressTests {
    let hyper: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    func interpret(_ keyCode: Int, _ flags: NSEvent.ModifierFlags, usedBy: String? = nil) -> ShortcutKeyPress {
        ShortcutKeyPress.interpret(keyCode: keyCode, modifierFlags: flags, usedBy: { _ in usedBy })
    }

    @Test func hyperWithAKeypadKeyRecordsEvenWithTheNumericPadAndCapsLockFlags() {
        let press = interpret(kVK_ANSI_Keypad1, hyper.union([.numericPad, .capsLock]))
        let expected = KeyboardShortcuts.Shortcut(.keypad1, modifiers: hyper)
        #expect(press == .record(expected))
        #expect(ShortcutKeyPress.label(expected) == "⌃⌥⇧⌘ Num 1")
    }

    @Test func numberRowKeysKeepTheLibraryLabel() {
        #expect(ShortcutKeyPress.label(.init(.two, modifiers: [.command, .shift])) == "⇧⌘2")
    }

    @Test func escapeAndTabCancelDeleteClears() {
        #expect(interpret(kVK_Escape, []) == .cancel)
        #expect(interpret(kVK_Tab, []) == .cancel)
        #expect(interpret(kVK_Delete, []) == .clear)
        #expect(interpret(kVK_ForwardDelete, []) == .clear)
    }

    @Test func modifiedEscapeAndDeleteRecord() {
        #expect(interpret(kVK_Delete, [.command, .option]) == .record(.init(.delete, modifiers: [.command, .option])))
    }

    @Test func shiftOrNoModifierIsRejectedUnlessItIsAFunctionKey() {
        #expect(interpret(kVK_ANSI_2, [.shift]) == .reject("⇧2 would fire while you type. Add ⌃, ⌥ or ⌘."))
        #expect(interpret(kVK_ANSI_Keypad3, []) == .reject("Num 3 would fire while you type. Add ⌃, ⌥ or ⌘."))
        #expect(interpret(kVK_F5, [.function]) == .record(.init(.f5)))
    }

    @Test func aShortcutAnotherGlintActionUsesIsRejectedByName() {
        #expect(interpret(kVK_ANSI_2, [.command, .shift], usedBy: "Capture Area") == .reject("⇧⌘2 is already the Capture Area shortcut."))
    }
}
