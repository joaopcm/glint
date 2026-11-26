import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Settings' picture of a window capture on the wallpaper: a sample window with `padding` on each side, scaled to fit
/// the preview and centered in it, so the spacing reads the way it will in the PNG.
public struct WallpaperPaddingPreview: Sendable, Equatable {
    /// The whole capture, wallpaper included, in preview points.
    public let canvas: CGRect
    /// The sample window inside the canvas, in preview points.
    public let window: CGRect

    /// The everyday window `LunettaSettings.windowWallpaperPaddingRange` is measured against.
    public static let sampleWindowSize = CGSize(width: 1000, height: 600)

    public init(canvas: CGRect, window: CGRect) {
        self.canvas = canvas
        self.window = window
    }

    /// Preview points per point of the real window.
    public var scale: CGFloat {
        window.width / Self.sampleWindowSize.width
    }

    public static func layout(padding: Double, in bounds: CGSize) -> WallpaperPaddingPreview {
        let padding = padding.isFinite ? max(CGFloat(padding), 0) : 0
        let capture = CGSize(width: sampleWindowSize.width + 2 * padding, height: sampleWindowSize.height + 2 * padding)
        let fit = max(min(bounds.width / capture.width, bounds.height / capture.height), 0)
        let canvas = CGRect(
            x: (bounds.width - capture.width * fit) / 2,
            y: (bounds.height - capture.height * fit) / 2,
            width: capture.width * fit,
            height: capture.height * fit
        )
        let window = CGRect(
            x: canvas.minX + padding * fit,
            y: canvas.minY + padding * fit,
            width: sampleWindowSize.width * fit,
            height: sampleWindowSize.height * fit
        )
        return WallpaperPaddingPreview(canvas: canvas, window: window)
    }
}
