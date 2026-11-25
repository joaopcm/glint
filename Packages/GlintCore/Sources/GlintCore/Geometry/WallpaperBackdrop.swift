import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Where a window capture sits on the slice of its display's wallpaper that was behind it.
public struct WallpaperBackdrop: Sendable, Equatable {
    /// Size of the finished image, in pixels.
    public let canvasSize: CGSize
    /// Top-left corner of the window image inside the canvas, in pixels.
    public let windowOrigin: CGPoint
    /// Part of the wallpaper stretched over the whole canvas, in points from the display's top-left corner.
    public let wallpaperRect: CGRect

    public init(canvasSize: CGSize, windowOrigin: CGPoint, wallpaperRect: CGRect) {
        self.canvasSize = canvasSize
        self.windowOrigin = windowOrigin
        self.wallpaperRect = wallpaperRect
    }

    /// `windowFrame` and `displayFrame` share one top-left global space. The slice is centered on the window and pushed
    /// back inside the display near its edges; a slice bigger than the display shrinks to fit and the wallpaper stretches.
    public static func layout(
        windowImageSize: CGSize,
        scale: CGFloat,
        windowFrame: CGRect,
        displayFrame: CGRect,
        padding: CGFloat
    ) -> WallpaperBackdrop {
        let paddingPixels = (max(padding, 0) * scale).rounded()
        let canvas = CGSize(width: windowImageSize.width + 2 * paddingPixels, height: windowImageSize.height + 2 * paddingPixels)
        let wanted = CGSize(width: canvas.width / scale, height: canvas.height / scale)
        let fit = min(1, displayFrame.width / wanted.width, displayFrame.height / wanted.height)
        let size = CGSize(width: wanted.width * fit, height: wanted.height * fit)
        let x = clamp(windowFrame.midX - displayFrame.minX - size.width / 2, upTo: displayFrame.width - size.width)
        let y = clamp(windowFrame.midY - displayFrame.minY - size.height / 2, upTo: displayFrame.height - size.height)
        return WallpaperBackdrop(
            canvasSize: canvas,
            windowOrigin: CGPoint(x: paddingPixels, y: paddingPixels),
            wallpaperRect: CGRect(x: x, y: y, width: size.width, height: size.height)
        )
    }

    private static func clamp(_ value: CGFloat, upTo upper: CGFloat) -> CGFloat {
        min(max(value, 0), max(upper, 0))
    }
}
