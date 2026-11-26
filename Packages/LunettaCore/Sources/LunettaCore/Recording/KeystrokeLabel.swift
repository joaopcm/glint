public struct KeyModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = KeyModifiers(rawValue: 1 << 0)
    public static let option = KeyModifiers(rawValue: 1 << 1)
    public static let shift = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)
}

/// The text the pressed-keys overlay shows for one key press, in the ⌃⌥⇧⌘ order macOS menus use.
public enum KeystrokeLabel {
    /// macOS virtual key codes (Carbon `kVK_*`) of keys that type nothing visible.
    static let namedKeys: [Int: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 76: "⌤", 117: "⌦",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    /// `characters` is what the key types without modifiers; nil when the press shows nothing.
    public static func text(keyCode: Int, characters: String?, modifiers: KeyModifiers) -> String? {
        let key: String
        if let named = namedKeys[keyCode] {
            key = named
        } else if let characters, let first = characters.first, !first.isWhitespace, !first.isNewline,
                  first.unicodeScalars.allSatisfy(isVisible) {
            key = characters.uppercased()
        } else {
            return nil
        }
        let glyphs: [(KeyModifiers, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        return glyphs.filter { modifiers.contains($0.0) }.map(\.1).joined() + key
    }

    /// Control characters, and the private-use range AppKit types for function keys (NSF1FunctionKey is U+F704).
    private static func isVisible(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 0x20 && scalar.value != 0x7F && !(0xF700...0xF8FF).contains(scalar.value)
    }
}
