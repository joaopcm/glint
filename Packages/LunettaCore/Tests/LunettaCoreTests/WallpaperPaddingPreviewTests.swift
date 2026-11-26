import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Testing
@testable import LunettaCore

private let bounds = CGSize(width: 500, height: 240)

@Test func noPaddingFillsTheCanvasWithTheWindow() {
    let preview = WallpaperPaddingPreview.layout(padding: 0, in: bounds)
    #expect(preview.canvas == CGRect(x: 50, y: 0, width: 400, height: 240))
    #expect(preview.window == preview.canvas)
    #expect(preview.scale == 0.4)
}

@Test func paddingShrinksTheWindowByTheSameShareAsTheCapture() {
    let preview = WallpaperPaddingPreview.layout(padding: 100, in: bounds)
    #expect(preview.canvas == CGRect(x: 70, y: 0, width: 360, height: 240))
    #expect(preview.window == CGRect(x: 100, y: 30, width: 300, height: 180))
    #expect(abs(preview.window.width / preview.canvas.width - 1000.0 / 1200.0) < 1e-9)
}

@Test func theWindowStaysCenteredOnTheCanvas() {
    for padding in stride(from: 0.0, through: 256, by: 8) {
        let preview = WallpaperPaddingPreview.layout(padding: padding, in: bounds)
        #expect(abs(preview.window.midX - preview.canvas.midX) < 1e-9)
        #expect(abs(preview.window.midY - preview.canvas.midY) < 1e-9)
        #expect(preview.canvas.width <= bounds.width + 1e-9 && preview.canvas.height <= bounds.height + 1e-9)
    }
}

@Test func morePaddingMeansASmallerWindow() {
    let widths = stride(from: 0.0, through: 256, by: 8).map { WallpaperPaddingPreview.layout(padding: $0, in: bounds).window.width }
    #expect(zip(widths, widths.dropFirst()).allSatisfy { $0 > $1 })
}

@Test(arguments: [-40.0, .nan, -.infinity])
func paddingBelowZeroOrNotANumberShowsNoPadding(padding: Double) {
    #expect(WallpaperPaddingPreview.layout(padding: padding, in: bounds) == WallpaperPaddingPreview.layout(padding: 0, in: bounds))
}

@Test func emptyBoundsGiveAnEmptyPreview() {
    let preview = WallpaperPaddingPreview.layout(padding: 64, in: .zero)
    #expect(preview.canvas.size == .zero)
    #expect(preview.window.size == .zero)
}
