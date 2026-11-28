import AppKit
import CoreGraphics
import LunettaUI
import Testing
@testable import Lunetta

@MainActor @Test func closeButtonGlassIsACircleAndTheActionBarACapsule() {
    let close = Glass.toolbar([iconButton()])
    let bar = Glass.toolbar((0..<5).map { _ in iconButton() })
    close.layoutSubtreeIfNeeded()
    bar.layoutSubtreeIfNeeded()

    #expect(close.fittingSize == CGSize(width: 32, height: 32))
    #expect(bar.fittingSize.height == 32)
    #expect(bar.fittingSize.width > 32)
}

@MainActor private func iconButton() -> NSButton {
    let button = NSButton()
    button.imagePosition = .imageOnly
    return button
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

@MainActor @Test func cardsLeaveThroughTheEdgeOfTheirOwnHalf() {
    let screen = CGRect(x: 0, y: 0, width: 3008, height: 1692)
    let right = ThumbnailPresenter.frame(at: 0, in: screen, corner: .bottomRight, collapsed: false, width: 240)!
    let left = ThumbnailPresenter.frame(at: 0, in: screen, corner: .bottomLeft, collapsed: false, width: 240)!

    #expect(ThumbnailPresenter.edge(of: right, on: screen) == .right)
    #expect(ThumbnailPresenter.edge(of: left, on: screen) == .left)
    #expect(ThumbnailPresenter.offscreen(right, toward: .right, of: screen) == CGRect(x: 3008, y: right.minY, width: 240, height: 160))
    #expect(ThumbnailPresenter.offscreen(left, toward: .left, of: screen) == CGRect(x: -240, y: left.minY, width: 240, height: 160))
}

@MainActor @Test func offscreenRespectsADisplayThatDoesNotStartAtZero() {
    let secondDisplay = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
    let card = CGRect(x: -1900, y: 24, width: 240, height: 160)

    #expect(ThumbnailPresenter.edge(of: card, on: secondDisplay) == .left)
    #expect(ThumbnailPresenter.offscreen(card, toward: .left, of: secondDisplay).maxX == -1920)
}

@MainActor @Test func swipeLeavesTheWayTheFingersMoved() {
    #expect(ThumbnailPresenter.swipeEdge(scrollDelta: 80, naturalScrolling: true) == .right)
    #expect(ThumbnailPresenter.swipeEdge(scrollDelta: -80, naturalScrolling: true) == .left)
    #expect(ThumbnailPresenter.swipeEdge(scrollDelta: 80, naturalScrolling: false) == .left)
    #expect(ThumbnailPresenter.swipeEdge(scrollDelta: -80, naturalScrolling: false) == .right)
}

@MainActor @Test func tallCardShowsHeightBadge() throws {
    let thumbnail = try image(width: 300, height: 200, opaque: CGRect(x: 0, y: 0, width: 300, height: 200))
    let url = URL(fileURLWithPath: "/tmp/capture.png")

    let tall = ThumbnailView(url: url, thumbnail: thumbnail, isVideo: false, fullPixelSize: CGSize(width: 1600, height: 12480))
    let badge = try #require(heightBadge(in: tall))
    #expect(badge.stringValue == "↕ \(12_480.formatted()) px")
    #expect(!badge.isHiddenOrHasHiddenAncestor)

    let normal = ThumbnailView(url: url, thumbnail: thumbnail, isVideo: false, fullPixelSize: CGSize(width: 1600, height: 1000))
    #expect(heightBadge(in: normal).map(\.isHiddenOrHasHiddenAncestor) ?? true)
}

@MainActor private func heightBadge(in view: NSView) -> NSTextField? {
    if let field = view as? NSTextField, field.accessibilityIdentifier() == AccessibilityID.cardHeightBadge { return field }
    return view.subviews.lazy.compactMap { heightBadge(in: $0) }.first
}
