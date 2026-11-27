import CoreGraphics
import Foundation

/// Maps a dock slider's position, 0 to 1, onto a size in points. The scale is geometric, so every stretch of the slider
/// changes the look as much.
struct SliderScale: Sendable {
    let lightest: CGFloat
    let heaviest: CGFloat
    let standard: Double

    /// How hard a blur or pixelate hides what's under it. Each third of the slider doubles the size (6, 12, 24, 48 pt).
    static let obscuring = SliderScale(
        lightest: 6,
        // Past the 28 pt line the text tool writes, so even the biggest text on a capture turns into one block.
        heaviest: 48,
        // 12 pt, the size before the slider existed: just under the 13 pt system font (`NSFont.systemFontSize`),
        // so a glyph turns into one smear or one block.
        standard: 1.0 / 3
    )

    /// An arrow's line width. Each half of the slider triples it (2, 6, 18 pt).
    static let arrowThickness = SliderScale(
        lightest: 2,
        heaviest: 18,
        // 6 pt, the width before the slider existed: about half the cursor's width, measured against the cursor in the
        // reference arrow the redesign copies.
        standard: 0.5
    )

    func size(at level: Double, pixelsPerPoint: CGFloat) -> CGFloat {
        let level = CGFloat(min(max(level, 0), 1))
        return lightest * pow(heaviest / lightest, level) * pixelsPerPoint
    }

    func level(of size: CGFloat, pixelsPerPoint: CGFloat) -> Double {
        let level = log(size / pixelsPerPoint / lightest) / log(heaviest / lightest)
        return min(max(Double(level), 0), 1)
    }
}
