import AppKit
import CoreGraphics
import Testing
@testable import Glint

@MainActor @Test func closeButtonGlassIsACircleAndTheActionBarACapsule() {
    let close = Glass.toolbar([NSButton()])
    let bar = Glass.toolbar((0..<5).map { _ in NSButton() })
    close.layoutSubtreeIfNeeded()
    bar.layoutSubtreeIfNeeded()

    #expect(close.fittingSize == CGSize(width: 32, height: 32))
    #expect(bar.fittingSize.height == 32)
    #expect(bar.fittingSize.width > 32)
}

@MainActor @Test func marginIsTwentyFourPoints() {
    #expect(ThumbnailPresenter.margin == 24)
}

@Test func cropEvensOutTheMeasuredWindowShadow() {
    // 400x332 pt window on a 2x display: 46 px of shadow left and right, 32 px above, 60 px below (#91).
    let size = CGSize(width: 892, height: 756)
    let window = CGRect(x: 46, y: 32, width: 800, height: 664)

    let crop = ThumbnailCentering.evenPaddingCrop(size: size, opaque: window)

    #expect(crop == CGRect(x: 0, y: 0, width: 892, height: 728))
    #expect(window.minY - crop.minY == crop.maxY - window.maxY)
}

@Test func centeringFindsTheWindowInsideItsShadowAndLeavesOpaqueImagesAlone() throws {
    let shadowed = try image(width: 120, height: 100, opaque: CGRect(x: 10, y: 6, width: 100, height: 80))
    #expect(ThumbnailCentering.opaqueBounds(of: shadowed) == CGRect(x: 10, y: 14, width: 100, height: 80))

    let centered = ThumbnailCentering.centered(shadowed)
    #expect(centered.width == 120 && centered.height == 92)

    let screen = try image(width: 160, height: 90, opaque: CGRect(x: 0, y: 0, width: 160, height: 90))
    #expect(ThumbnailCentering.centered(screen).height == 90)
}

private func image(width: Int, height: Int, opaque: CGRect) throws -> CGImage {
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.4))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(opaque)
    return try #require(context.makeImage())
}

@Test func clickingARecordingOpensItAndClickingAScreenshotAnnotatesIt() {
    #expect(ThumbnailView.clickAction(isStacked: false, isVideo: true) == .open)
    #expect(ThumbnailView.clickAction(isStacked: false, isVideo: false) == .annotate)
    #expect(ThumbnailView.clickAction(isStacked: true, isVideo: true) == .expand)
    #expect(ThumbnailView.clickAction(isStacked: true, isVideo: false) == .expand)
}
