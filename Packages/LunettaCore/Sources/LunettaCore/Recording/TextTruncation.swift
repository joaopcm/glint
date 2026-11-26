import Foundation

public enum TextTruncation {
    /// `text` when it fits `width`, otherwise its longest start that fits with "…" after it. `measure` gives a
    /// string's drawn width, so the caller's font decides.
    public static func tail(_ text: String, fitting width: Double, measure: (String) -> Double) -> String {
        guard measure(text) > width else { return text }
        var kept = 0
        var tooMany = text.count
        while tooMany - kept > 1 {
            let tried = (kept + tooMany) / 2
            if measure(ellipsized(text, keeping: tried)) <= width { kept = tried } else { tooMany = tried }
        }
        return ellipsized(text, keeping: kept)
    }

    private static func ellipsized(_ text: String, keeping count: Int) -> String {
        String(text.prefix(count)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
