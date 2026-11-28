import KeyboardShortcuts
import Testing
@testable import Lunetta

@MainActor final class FakeShortcutStore: ShortcutStore {
    var saved: [KeyboardShortcuts.Name: KeyboardShortcuts.Shortcut] = [:]
    var writes: [(KeyboardShortcuts.Name, KeyboardShortcuts.Shortcut?)] = []

    func shortcut(for name: KeyboardShortcuts.Name) -> KeyboardShortcuts.Shortcut? { saved[name] }

    func setShortcut(_ shortcut: KeyboardShortcuts.Shortcut?, for name: KeyboardShortcuts.Name) {
        writes.append((name, shortcut))
        saved[name] = shortcut
    }
}

@MainActor struct ShortcutBindingsTests {
    let names = LunettaShortcuts.all.map(\.name)
    let hyperKeypad1 = KeyboardShortcuts.Shortcut(.keypad1, modifiers: [.control, .option, .shift, .command])

    @Test func everyLunettaShortcutHasTheDocumentedDefault() {
        let defaults = names.map { $0.defaultShortcut.map(ShortcutKeyPress.label) }
        #expect(defaults == ["⇧⌘2", "⌃⇧⌘2", "⇧⌘1", "⌥⇧⌘2", "⌥⇧⌘5", "⌃⌥⇧⌘5"])
    }

    @Test func restoreWritesEveryDefaultThroughTheStoreThatRegistersHotkeys() {
        let store = FakeShortcutStore()
        let bindings = ShortcutBindings(names: names, store: store)
        #expect(!bindings.areDefaults)

        bindings.restoreDefaults()

        #expect(store.writes.map(\.0) == names)
        #expect(store.writes.map(\.1) == names.map(\.defaultShortcut))
        #expect(bindings.areDefaults)
        #expect(bindings.shortcuts[.captureArea] == KeyboardShortcuts.Name.captureArea.defaultShortcut)
    }

    @Test func undoPutsBackCustomAndClearedShortcuts() {
        let store = FakeShortcutStore()
        store.saved[.captureArea] = hyperKeypad1
        let bindings = ShortcutBindings(names: names, store: store)

        bindings.restoreDefaults()
        #expect(bindings.canUndoRestore)
        bindings.undoRestore()

        #expect(store.saved == [.captureArea: hyperKeypad1])
        #expect(bindings.shortcuts == [.captureArea: hyperKeypad1])
        #expect(!bindings.canUndoRestore)
    }

    @Test func recordingAShortcutAfterARestoreDropsTheUndo() {
        let bindings = ShortcutBindings(names: names, store: FakeShortcutStore())
        bindings.restoreDefaults()
        bindings.set(hyperKeypad1, for: .captureWindow)

        #expect(!bindings.canUndoRestore)
        #expect(bindings.shortcuts[.captureWindow] == hyperKeypad1)
        #expect(!bindings.areDefaults)
    }
}
