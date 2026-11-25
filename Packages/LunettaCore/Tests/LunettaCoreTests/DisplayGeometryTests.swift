import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Testing
@testable import LunettaCore

private let main = DisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 2)
private let ext = DisplayInfo(id: 2, frame: CGRect(x: -1920, y: -200, width: 1920, height: 1080), scale: 1)
private let above = DisplayInfo(id: 3, frame: CGRect(x: 0, y: 982, width: 1512, height: 1080), scale: 1)

@Test func mainDisplayFlipsY() {
    #expect(DisplayGeometry.sourceRect(for: CGRect(x: 100, y: 782, width: 200, height: 100), on: main) == CGRect(x: 100, y: 100, width: 200, height: 100))
}

@Test func negativeOriginDisplay() {
    #expect(DisplayGeometry.sourceRect(for: CGRect(x: -1820, y: 680, width: 300, height: 100), on: ext) == CGRect(x: 100, y: 100, width: 300, height: 100))
}

@Test func displayAboveMainMapsToLocalTopLeft() {
    #expect(DisplayGeometry.sourceRect(for: CGRect(x: 10, y: 1000, width: 200, height: 100), on: above) == CGRect(x: 10, y: 962, width: 200, height: 100))
}

@Test func selectionSpanningDisplaysPicksLargerShareAndClips() {
    let sel = CGRect(x: -100, y: 100, width: 600, height: 100)
    #expect(DisplayGeometry.display(forSelection: sel, in: [main, ext]) == main)
    #expect(DisplayGeometry.sourceRect(for: sel, on: main)?.width == 500)
}

@Test func selectionOffAllDisplaysHasNoDisplay() {
    #expect(DisplayGeometry.display(forSelection: CGRect(x: 5000, y: 5000, width: 100, height: 100), in: [main, ext]) == nil)
}

@Test func scaleForDisplay() {
    let size = CGRect(x: 0, y: 0, width: 200, height: 100)
    let retina = DisplayGeometry.pixelSize(of: size, scale: main.scale)
    let standard = DisplayGeometry.pixelSize(of: size, scale: ext.scale)
    #expect(retina.width == 400 && retina.height == 200)
    #expect(standard.width == 200 && standard.height == 100)
}

@Test func pixelSizeRoundsToNearestPixel() {
    let size = DisplayGeometry.pixelSize(of: CGRect(x: 10, y: 10, width: 100.5, height: 50.2), scale: 2)
    #expect(size.width == 201 && size.height == 100)
}

@Test(arguments: [CGFloat(1), 2])
func pixelSizeIgnoresOrigin(scale: CGFloat) {
    let atZero = DisplayGeometry.pixelSize(of: CGRect(x: 0, y: 0, width: 333.5, height: 101.75), scale: scale)
    let offset = DisplayGeometry.pixelSize(of: CGRect(x: -1820.25, y: 680.5, width: 333.5, height: 101.75), scale: scale)
    #expect(atZero == offset)
}

@Test func zeroAreaSelectionIsCancel() {
    #expect(DisplayGeometry.sourceRect(for: CGRect(x: 10, y: 10, width: 0, height: 0), on: main) == nil)
}

@Test func selectionOutsideDisplayHasNoSourceRect() {
    #expect(DisplayGeometry.sourceRect(for: CGRect(x: 5000, y: 5000, width: 100, height: 100), on: main) == nil)
}

@Test func pointOnExternal() {
    #expect(DisplayGeometry.display(containing: CGPoint(x: -5, y: 0), in: [main, ext]) == ext)
}

@Test func sharedEdgeMinXBelongsToDisplayStartingThere() {
    #expect(DisplayGeometry.display(containing: CGPoint(x: 0, y: 0), in: [main, ext]) == main)
    #expect(DisplayGeometry.display(containing: CGPoint(x: 0, y: 0), in: [ext, main]) == main)
}

@Test func nearestDisplayContainingPoint() {
    #expect(DisplayGeometry.display(nearest: CGPoint(x: -5, y: 0), in: [main, ext]) == ext)
}

@Test func nearestDisplayAtMainTopEdge() {
    #expect(DisplayGeometry.display(nearest: CGPoint(x: 700, y: 982), in: [main, ext]) == main)
}

@Test func nearestDisplayAtMainRightEdge() {
    #expect(DisplayGeometry.display(nearest: CGPoint(x: 1512, y: 400), in: [main, ext]) == main)
}

@Test func nearestDisplayFarOutside() {
    #expect(DisplayGeometry.display(nearest: CGPoint(x: -5000, y: 300), in: [main, ext]) == ext)
    #expect(DisplayGeometry.display(nearest: CGPoint(x: 9000, y: 9000), in: [main, ext]) == main)
}

@Test func nearestDisplayInEmptyList() {
    #expect(DisplayGeometry.display(nearest: .zero, in: []) == nil)
}

@Test func appKitRectOnMainDisplay() {
    let rect = DisplayGeometry.appKitRect(fromTopLeftGlobal: CGRect(x: 100, y: 50, width: 400, height: 300), mainDisplayHeight: 982)
    #expect(rect == CGRect(x: 100, y: 632, width: 400, height: 300))
}

@Test func appKitRectOnDisplayAboveMain() {
    let rect = DisplayGeometry.appKitRect(fromTopLeftGlobal: CGRect(x: 10, y: -1000, width: 200, height: 100), mainDisplayHeight: 982)
    #expect(rect == CGRect(x: 10, y: 1882, width: 200, height: 100))
    #expect(above.frame.contains(rect))
}

@Test func appKitRectOnDisplayLeftOfMain() {
    let rect = DisplayGeometry.appKitRect(fromTopLeftGlobal: CGRect(x: -1820, y: 202, width: 300, height: 100), mainDisplayHeight: 982)
    #expect(rect == CGRect(x: -1820, y: 680, width: 300, height: 100))
    #expect(ext.frame.contains(rect))
}

@Test func frozenCropMatchesSelectionInPixelsOnRetina() {
    let source = DisplayGeometry.sourceRect(for: CGRect(x: 100, y: 782, width: 200, height: 100), on: main)!
    #expect(DisplayGeometry.pixelRect(of: source, on: main) == CGRect(x: 200, y: 200, width: 400, height: 200))
}

@Test func frozenCropMatchesSelectionInPixelsOnStandard() {
    let source = DisplayGeometry.sourceRect(for: CGRect(x: -1820, y: 680, width: 300, height: 100), on: ext)!
    #expect(DisplayGeometry.pixelRect(of: source, on: ext) == CGRect(x: 100, y: 100, width: 300, height: 100))
}

@Test func frozenCropSizeAgreesWithPixelSizeForFractionalPoints() {
    let source = CGRect(x: 10.3, y: 20.7, width: 50.4, height: 30.6)
    let rect = DisplayGeometry.pixelRect(of: source, on: main)
    let size = DisplayGeometry.pixelSize(of: source, scale: main.scale)
    #expect(rect.width == CGFloat(size.width) && rect.height == CGFloat(size.height))
    #expect(rect.origin == CGPoint(x: 21, y: 41))
}
