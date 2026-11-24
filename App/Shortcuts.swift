import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let captureArea = Self("captureArea", default: .init(.two, modifiers: [.command, .shift]))
    static let captureWindow = Self("captureWindow", default: .init(.two, modifiers: [.control, .command, .shift]))
    static let captureFullScreen = Self("captureFullScreen", default: .init(.one, modifiers: [.command, .shift]))
    static let captureText = Self("captureText", default: .init(.two, modifiers: [.option, .command, .shift]))
    // ⇧⌘3/4/5 belong to macOS's own screenshot and recording tools; ⌥ keeps the 5 mnemonic without taking them.
    static let recordArea = Self("recordArea", default: .init(.five, modifiers: [.option, .command, .shift]))
    static let recordWindow = Self("recordWindow", default: .init(.five, modifiers: [.control, .option, .command, .shift]))
}
