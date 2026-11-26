import Testing
@testable import LunettaCore

@Test func modifiersComeInMenuOrderBeforeTheKey() {
    #expect(KeystrokeLabel.text(keyCode: 1, characters: "s", modifiers: [.command, .shift, .option, .control]) == "⌃⌥⇧⌘S")
    #expect(KeystrokeLabel.text(keyCode: 8, characters: "c", modifiers: .command) == "⌘C")
}

@Test func aPlainKeyShowsAlone() {
    #expect(KeystrokeLabel.text(keyCode: 0, characters: "a", modifiers: []) == "A")
    #expect(KeystrokeLabel.text(keyCode: 18, characters: "1", modifiers: []) == "1")
}

@Test(arguments: [(36, "↩"), (48, "⇥"), (49, "Space"), (51, "⌫"), (53, "⎋"), (123, "←"), (126, "↑"), (122, "F1"), (111, "F12")])
func keysThatTypeNothingVisibleAreNamed(keyCode: Int, label: String) {
    #expect(KeystrokeLabel.text(keyCode: keyCode, characters: "\u{F704}", modifiers: []) == label)
}

@Test func keysWithNothingToShowShowNothing() {
    #expect(KeystrokeLabel.text(keyCode: 200, characters: nil, modifiers: .command) == nil)
    #expect(KeystrokeLabel.text(keyCode: 200, characters: "", modifiers: []) == nil)
    #expect(KeystrokeLabel.text(keyCode: 200, characters: "\u{F72D}", modifiers: []) == nil)
    #expect(KeystrokeLabel.text(keyCode: 200, characters: "\u{1B}", modifiers: []) == nil)
}
