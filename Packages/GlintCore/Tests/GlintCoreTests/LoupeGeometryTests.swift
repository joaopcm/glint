import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Testing
@testable import GlintCore

private let main = DisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 2)
private let ext = DisplayInfo(id: 2, frame: CGRect(x: -1920, y: -200, width: 1920, height: 1080), scale: 1)
private let size = CGSize(width: 120, height: 120)
private let offset: CGFloat = 16

@Test func loupeSitsBelowRightByDefault() {
    let frame = LoupeGeometry.frame(size: size, pointer: CGPoint(x: 500, y: 500), in: main.frame, offset: offset)
    #expect(frame == CGRect(x: 516, y: 364, width: 120, height: 120))
}

@Test func flipsLeftAtRightEdge() {
    let frame = LoupeGeometry.frame(size: size, pointer: CGPoint(x: 1500, y: 500), in: main.frame, offset: offset)
    #expect(frame.maxX == 1484)
}

@Test func flipsAboveAtBottomEdge() {
    let frame = LoupeGeometry.frame(size: size, pointer: CGPoint(x: 500, y: 10), in: main.frame, offset: offset)
    #expect(frame.minY == 26)
}

@Test(arguments: [main, ext])
func staysOnScreenForEveryCorner(display: DisplayInfo) {
    let screen = display.frame
    let corners = [
        CGPoint(x: screen.minX, y: screen.minY),
        CGPoint(x: screen.maxX, y: screen.minY),
        CGPoint(x: screen.minX, y: screen.maxY),
        CGPoint(x: screen.maxX, y: screen.maxY),
    ]
    for corner in corners {
        let frame = LoupeGeometry.frame(size: size, pointer: corner, in: screen, offset: offset)
        #expect(screen.contains(frame), "loupe \(frame) left \(screen) at corner \(corner)")
    }
}

@Test func pixelUsesTopLeftOriginAndScale() {
    #expect(LoupeGeometry.pixel(at: CGPoint(x: 10.3, y: 981.9), on: main) == LoupePixel(x: 20, y: 0))
    #expect(LoupeGeometry.pixel(at: CGPoint(x: -1920, y: -200), on: ext) == LoupePixel(x: 0, y: 1079))
}

@Test func pixelClampsAtMaxEdge() {
    #expect(LoupeGeometry.pixel(at: CGPoint(x: 1512, y: 0), on: main) == LoupePixel(x: 3023, y: 1963))
}
