import Foundation
import Testing
@testable import LunettaCore

private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
private let area = CGRect(x: 200, y: 100, width: 800, height: 600)

@Test func theBubbleStartsInTheBottomRightCornerOnTheKeysMargin() {
    let frame = CameraBubbleGeometry.initialFrame(in: area)
    #expect(frame == CGRect(x: 1000 - 24 - 150, y: 100 + 24, width: 150, height: 150))
}

@Test func theBubbleIsAQuarterOfTheShorterSideUpToTheCap() {
    #expect(CameraBubbleGeometry.diameter(in: area) == 150)
    #expect(CameraBubbleGeometry.diameter(in: screen) == 180)
    #expect(CameraBubbleGeometry.diameter(in: CGRect(x: 0, y: 0, width: 2000, height: 80)) == 20)
}

@Test func aTinyAreaStillHoldsTheWholeBubble() {
    let tiny = CGRect(x: 10, y: 10, width: 30, height: 30)
    let frame = CameraBubbleGeometry.initialFrame(in: tiny)
    #expect(tiny.contains(frame))
}

@Test func aDragMovesTheBubbleByThePointersOffset() {
    let start = CameraBubbleGeometry.initialFrame(in: area)
    let moved = CameraBubbleGeometry.dragged(start, by: CGPoint(x: -300, y: 200), within: area)
    #expect(moved == start.offsetBy(dx: -300, dy: 200))
}

@Test(arguments: [CGPoint(x: -5000, y: 0), CGPoint(x: 5000, y: 0), CGPoint(x: 0, y: -5000), CGPoint(x: 0, y: 5000), CGPoint(x: 5000, y: 5000)])
func aDragPastAnEdgeStopsWithTheBubbleWholeInsideTheArea(offset: CGPoint) {
    let start = CameraBubbleGeometry.initialFrame(in: area)
    let moved = CameraBubbleGeometry.dragged(start, by: offset, within: area)
    #expect(area.contains(moved))
    #expect(moved.size == start.size)
}

@Test func aDragIntoACornerSitsFlushWithIt() {
    let start = CameraBubbleGeometry.initialFrame(in: area)
    let topLeft = CameraBubbleGeometry.dragged(start, by: CGPoint(x: -5000, y: 5000), within: area)
    #expect(topLeft.origin == CGPoint(x: area.minX, y: area.maxY - start.height))
}
