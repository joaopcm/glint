import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Testing
@testable import LunettaCore

private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)

@Test func paddingGrowsTheCanvasInPixelsAndCentersTheSliceOnTheWindow() {
    let backdrop = WallpaperBackdrop.layout(
        windowImageSize: CGSize(width: 800, height: 600),
        scale: 2,
        windowFrame: CGRect(x: 400, y: 200, width: 400, height: 300),
        displayFrame: screen,
        padding: 64
    )
    #expect(backdrop.canvasSize == CGSize(width: 1056, height: 856))
    #expect(backdrop.windowOrigin == CGPoint(x: 128, y: 128))
    #expect(backdrop.wallpaperRect == CGRect(x: 336, y: 136, width: 528, height: 428))
}

@Test func zeroPaddingKeepsTheWindowSize() {
    let backdrop = WallpaperBackdrop.layout(
        windowImageSize: CGSize(width: 400, height: 300),
        scale: 1,
        windowFrame: CGRect(x: 100, y: 100, width: 400, height: 300),
        displayFrame: screen,
        padding: 0
    )
    #expect(backdrop.canvasSize == CGSize(width: 400, height: 300))
    #expect(backdrop.windowOrigin == .zero)
    #expect(backdrop.wallpaperRect == CGRect(x: 100, y: 100, width: 400, height: 300))
}

@Test func windowAtTheScreenCornerKeepsTheSliceOnTheScreen() {
    let backdrop = WallpaperBackdrop.layout(
        windowImageSize: CGSize(width: 400, height: 300),
        scale: 1,
        windowFrame: CGRect(x: 1200, y: 0, width: 400, height: 300),
        displayFrame: screen,
        padding: 50
    )
    #expect(backdrop.wallpaperRect == CGRect(x: 1012, y: 0, width: 500, height: 400))
}

@Test func sliceBiggerThanTheScreenShrinksToFitAndKeepsTheCanvasAspect() {
    let backdrop = WallpaperBackdrop.layout(
        windowImageSize: CGSize(width: 1400, height: 900),
        scale: 1,
        windowFrame: CGRect(x: 56, y: 41, width: 1400, height: 900),
        displayFrame: screen,
        padding: 100
    )
    #expect(backdrop.canvasSize == CGSize(width: 1600, height: 1100))
    let slice = backdrop.wallpaperRect
    #expect(screen.contains(slice))
    #expect(abs(slice.width / slice.height - 1600 / 1100) < 0.0001)
    #expect(slice.height == 982)
}

@Test func secondaryDisplayGivesSliceInItsOwnPoints() {
    let backdrop = WallpaperBackdrop.layout(
        windowImageSize: CGSize(width: 200, height: 100),
        scale: 1,
        windowFrame: CGRect(x: -1000, y: 300, width: 200, height: 100),
        displayFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
        padding: 10
    )
    #expect(backdrop.wallpaperRect == CGRect(x: 910, y: 290, width: 220, height: 120))
}
