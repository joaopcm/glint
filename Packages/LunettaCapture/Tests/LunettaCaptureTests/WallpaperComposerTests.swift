import CoreGraphics
import LunettaCore
import Testing
@testable import LunettaCapture

private struct RGBA: Equatable {
    let r, g, b, a: UInt8
    static let red = RGBA(r: 255, g: 0, b: 0, a: 255)
    static let green = RGBA(r: 0, g: 255, b: 0, a: 255)
    static let blue = RGBA(r: 0, g: 0, b: 255, a: 255)
}

private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

private func context(width: Int, height: Int, data: UnsafeMutableRawPointer? = nil) -> CGContext {
    CGContext(
        data: data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
}

/// Rects are top-left, like the PNG the user sees.
private func image(width: Int, height: Int, fills: [(CGRect, RGBA)]) -> CGImage {
    let canvas = context(width: width, height: height)
    for (rect, color) in fills {
        canvas.setFillColor(red: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255, blue: CGFloat(color.b) / 255, alpha: 1)
        canvas.fill(CGRect(x: rect.minX, y: CGFloat(height) - rect.maxY, width: rect.width, height: rect.height))
    }
    return canvas.makeImage()!
}

private func pixel(_ image: CGImage, x: Int, y: Int) -> RGBA {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    bytes.withUnsafeMutableBytes { buffer in
        context(width: image.width, height: image.height, data: buffer.baseAddress)
            .draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    let offset = (y * image.width + x) * 4
    return RGBA(r: bytes[offset], g: bytes[offset + 1], b: bytes[offset + 2], a: bytes[offset + 3])
}

// Wallpaper: blue over green, 20 × 10. Window: 4 × 2, red on its left half, transparent (shadow) on its right half.
private let wallpaper = image(width: 20, height: 10, fills: [
    (CGRect(x: 0, y: 0, width: 20, height: 5), .blue),
    (CGRect(x: 0, y: 5, width: 20, height: 5), .green),
])
private let window = image(width: 4, height: 2, fills: [(CGRect(x: 0, y: 0, width: 2, height: 2), .red)])
private let backdrop = WallpaperBackdrop(
    canvasSize: CGSize(width: 8, height: 6),
    windowOrigin: CGPoint(x: 2, y: 2),
    wallpaperRect: CGRect(x: 6, y: 2, width: 8, height: 6)
)

@Test func windowSitsOnTheWallpaperSliceAtItsOrigin() throws {
    let composed = try #require(WallpaperComposer.compose(window: window, on: wallpaper, wallpaperScale: 1, backdrop: backdrop))
    #expect(composed.width == 8 && composed.height == 6)
    #expect(pixel(composed, x: 0, y: 0) == .blue)
    #expect(pixel(composed, x: 7, y: 5) == .green)
    #expect(pixel(composed, x: 2, y: 2) == .red)
    #expect(pixel(composed, x: 3, y: 3) == .red)
    #expect(pixel(composed, x: 1, y: 2) == .blue, "the window started left of its origin")
    #expect(pixel(composed, x: 2, y: 4) == .green, "the window ran below its origin + height")
}

@Test func transparentWindowPixelsShowTheWallpaper() throws {
    let composed = try #require(WallpaperComposer.compose(window: window, on: wallpaper, wallpaperScale: 1, backdrop: backdrop))
    #expect(pixel(composed, x: 5, y: 2) == .blue)
    #expect(pixel(composed, x: 5, y: 3) == .green)
}

@Test func retinaWallpaperIsSlicedInPixels() throws {
    let retinaWallpaper = image(width: 40, height: 20, fills: [
        (CGRect(x: 0, y: 0, width: 40, height: 10), .blue),
        (CGRect(x: 0, y: 10, width: 40, height: 10), .green),
    ])
    let bottomHalf = WallpaperBackdrop(canvasSize: CGSize(width: 8, height: 6), windowOrigin: CGPoint(x: 2, y: 2), wallpaperRect: CGRect(x: 0, y: 5, width: 20, height: 5))
    let composed = try #require(WallpaperComposer.compose(window: window, on: retinaWallpaper, wallpaperScale: 2, backdrop: bottomHalf))
    #expect(pixel(composed, x: 0, y: 0) == .green, "the slice read the wallpaper's points as pixels and landed in the blue half")
}

@Test func onlyLayersBelowTheDesktopIconsCountAsWallpaper() {
    #expect(ScreenCapturer.isWallpaperLayer(Int(CGWindowLevelForKey(.desktopWindow))))
    #expect(!ScreenCapturer.isWallpaperLayer(Int(CGWindowLevelForKey(.desktopIconWindow))))
    #expect(!ScreenCapturer.isWallpaperLayer(0))
}
