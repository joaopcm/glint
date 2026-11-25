import AppKit
import GlintCore
import Testing
@testable import Glint

private let display = DisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 200, height: 200), scale: 1)

@MainActor private func view(showsLoupe: Bool, backdrop: CGImage? = nil) -> AreaSelectionView {
    AreaSelectionView(screenFrame: display.frame, display: display, displays: [display], showsLoupe: showsLoupe, backdrop: backdrop)
}

@MainActor @Test(arguments: [true, false]) func liveOverlayGrabsTheScreenOnlyForTheLoupe(showsLoupe: Bool) {
    #expect(view(showsLoupe: showsLoupe).needsSnapshot == showsLoupe)
}

@MainActor @Test(arguments: [true, false]) func loupeFollowsThePointerOnlyWhenTheMagnifierIsOn(showsLoupe: Bool) throws {
    let context = try #require(CGContext(
        data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    let frozen = view(showsLoupe: showsLoupe, backdrop: try #require(context.makeImage()))
    frozen.updateLoupe(at: CGPoint(x: 100, y: 100))
    #expect(frozen.needsSnapshot == false)
    #expect(frozen.accessibilityChildren()?.count == (showsLoupe ? 1 : 0))
}
