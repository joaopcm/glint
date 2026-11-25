import KeyboardShortcuts
import Observation

@MainActor protocol ShortcutStore {
    func shortcut(for name: KeyboardShortcuts.Name) -> KeyboardShortcuts.Shortcut?
    func setShortcut(_ shortcut: KeyboardShortcuts.Shortcut?, for name: KeyboardShortcuts.Name)
}

struct KeyboardShortcutsStore: ShortcutStore {
    func shortcut(for name: KeyboardShortcuts.Name) -> KeyboardShortcuts.Shortcut? {
        KeyboardShortcuts.getShortcut(for: name)
    }

    func setShortcut(_ shortcut: KeyboardShortcuts.Shortcut?, for name: KeyboardShortcuts.Name) {
        KeyboardShortcuts.setShortcut(shortcut, for: name)
    }
}

@MainActor @Observable final class ShortcutBindings {
    let names: [KeyboardShortcuts.Name]
    private let store: any ShortcutStore
    private(set) var shortcuts: [KeyboardShortcuts.Name: KeyboardShortcuts.Shortcut] = [:]
    private var beforeRestore: [KeyboardShortcuts.Name: KeyboardShortcuts.Shortcut]?

    init(names: [KeyboardShortcuts.Name], store: any ShortcutStore = KeyboardShortcutsStore()) {
        self.names = names
        self.store = store
        reload()
    }

    var areDefaults: Bool { names.allSatisfy { shortcuts[$0] == $0.defaultShortcut } }
    var canUndoRestore: Bool { beforeRestore != nil }

    func set(_ shortcut: KeyboardShortcuts.Shortcut?, for name: KeyboardShortcuts.Name) {
        beforeRestore = nil
        store.setShortcut(shortcut, for: name)
        reload()
    }

    func restoreDefaults() {
        let previous = shortcuts
        for name in names {
            store.setShortcut(name.defaultShortcut, for: name)
        }
        reload()
        beforeRestore = previous
    }

    func undoRestore() {
        guard let beforeRestore else { return }
        self.beforeRestore = nil
        for name in names {
            store.setShortcut(beforeRestore[name], for: name)
        }
        reload()
    }

    func reload() {
        shortcuts = Dictionary(uniqueKeysWithValues: names.compactMap { name in store.shortcut(for: name).map { (name, $0) } })
    }
}
