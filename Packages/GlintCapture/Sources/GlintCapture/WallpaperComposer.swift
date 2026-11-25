import CoreGraphics
import GlintCore

enum WallpaperComposer {
    /// `wallpaper` is a full-display grab at `wallpaperScale` pixels per point.
    static func compose(window: CGImage, on wallpaper: CGImage, wallpaperScale: CGFloat, backdrop: WallpaperBackdrop) -> CGImage? {
        let slice = CGRect(
            x: backdrop.wallpaperRect.minX * wallpaperScale,
            y: backdrop.wallpaperRect.minY * wallpaperScale,
            width: backdrop.wallpaperRect.width * wallpaperScale,
            height: backdrop.wallpaperRect.height * wallpaperScale
        ).integral
        let width = Int(backdrop.canvasSize.width)
        let height = Int(backdrop.canvasSize.height)
        guard let wallpaperSlice = wallpaper.cropping(to: slice),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: window.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.interpolationQuality = .high
        context.draw(wallpaperSlice, in: CGRect(x: 0, y: 0, width: width, height: height))
        let windowRect = CGRect(
            x: backdrop.windowOrigin.x,
            y: CGFloat(height) - backdrop.windowOrigin.y - CGFloat(window.height),
            width: CGFloat(window.width),
            height: CGFloat(window.height)
        )
        context.draw(window, in: windowRect)
        return context.makeImage()
    }
}
