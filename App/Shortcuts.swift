import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let captureArea = Self("captureArea", default: .init(.two, modifiers: [.command, .shift]))
    static let captureWindow = Self("captureWindow", default: .init(.two, modifiers: [.control, .command, .shift]))
    static let captureFullScreen = Self("captureFullScreen", default: .init(.one, modifiers: [.command, .shift]))
    static let captureText = Self("captureText", default: .init(.two, modifiers: [.option, .command, .shift]))
}
