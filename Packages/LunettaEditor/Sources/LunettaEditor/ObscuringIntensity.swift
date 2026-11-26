import CoreGraphics
import Foundation

/// How hard a blur or pixelate hides what's under it, as the intensity slider's position from 0 to 1.
/// Each third of the slider doubles the size (6, 12, 24, 48 pt), so every stretch of it changes the look as much.
enum ObscuringIntensity {
    // 12 pt, the size before the slider existed: just under the 13 pt system font (`NSFont.systemFontSize`),
    // so a glyph turns into one smear or one block.
    static let standard = 1.0 / 3
    static let lightest: CGFloat = 6
    // Past the 28 pt line the text tool writes, so even the biggest text on a capture turns into one block.
    static let heaviest: CGFloat = 48

    static func size(at level: Double, pixelsPerPoint: CGFloat) -> CGFloat {
        let level = CGFloat(min(max(level, 0), 1))
        return lightest * pow(heaviest / lightest, level) * pixelsPerPoint
    }

    static func level(of size: CGFloat, pixelsPerPoint: CGFloat) -> Double {
        let level = log(size / pixelsPerPoint / lightest) / log(heaviest / lightest)
        return min(max(Double(level), 0), 1)
    }
}
