import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let captureArea = Self("captureArea", default: .init(.two, modifiers: [.command, .shift]))
    static let captureScrolling = Self("captureScrolling", default: .init(.four, modifiers: [.option, .command, .shift]))
    static let captureWindow = Self("captureWindow", default: .init(.two, modifiers: [.control, .command, .shift]))
    static let captureFullScreen = Self("captureFullScreen", default: .init(.one, modifiers: [.command, .shift]))
    static let captureText = Self("captureText", default: .init(.two, modifiers: [.option, .command, .shift]))
    // ⇧⌘3/4/5 belong to macOS's own screenshot and recording tools; ⌥ keeps the 5 mnemonic without taking them.
    static let recordArea = Self("recordArea", default: .init(.five, modifiers: [.option, .command, .shift]))
    static let recordWindow = Self("recordWindow", default: .init(.five, modifiers: [.control, .option, .command, .shift]))
    /// Registered only while the countdown runs, so Esc belongs to the frontmost app the rest of the time.
    static let cancelRecordingCountdown = Self("cancelRecordingCountdown", default: .init(.escape))
    /// Registered only while the scrolling stage is up, so Return and Esc belong to the frontmost app the rest of the time.
    static let finishScrollingCapture = Self("finishScrollingCapture", default: .init(.return))
    static let cancelScrollingCapture = Self("cancelScrollingCapture", default: .init(.escape))
}

enum LunettaShortcuts {
    static let all: [(title: String, name: KeyboardShortcuts.Name)] = [
        ("Capture Area", .captureArea),
        ("Capture Scrolling", .captureScrolling),
        ("Capture Window", .captureWindow),
        ("Capture Full Screen", .captureFullScreen),
        ("Capture Text", .captureText),
        ("Record Area", .recordArea),
        ("Record Window", .recordWindow),
    ]
}
