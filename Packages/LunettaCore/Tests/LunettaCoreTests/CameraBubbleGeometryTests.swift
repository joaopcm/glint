import Foundation
import Testing
@testable import LunettaCore

private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
private let area = CGRect(x: 200, y: 100, width: 800, height: 600)

@Test func theBubbleStartsInTheBottomRightCornerOnTheKeysMargin() {
    let frame = CameraBubbleGeometry.initialFrame(in: area)
    #expect(frame == CGRect(x: 1000 - 24 - 240, y: 100 + 24, width: 240, height: 240))
}

@Test func aSavedSizeStartsTheBubbleAtThatSize() {
    #expect(CameraBubbleGeometry.initialFrame(in: area, diameter: 300).size == CGSize(width: 300, height: 300))
}

@Test func theBubbleIsAtMostHalfTheAreasShorterSideAndNeverPastTheLimits() {
    #expect(CameraBubbleGeometry.diameters(in: screen) == 96...360)
    #expect(CameraBubbleGeometry.diameters(in: area) == 96...300)
    #expect(CameraBubbleGeometry.diameters(in: CGRect(x: 0, y: 0, width: 2000, height: 120)) == 60...60)
    #expect(CameraBubbleGeometry.initialFrame(in: CGRect(x: 0, y: 0, width: 400, height: 300)).width == 150)
}

@Test func aTinyAreaStillHoldsTheWholeBubble() {
    let tiny = CGRect(x: 10, y: 10, width: 30, height: 30)
    #expect(tiny.contains(CameraBubbleGeometry.initialFrame(in: tiny)))
}

@Test func onlyTheRingAlongTheEdgeResizes() {
    let frame = CGRect(x: 0, y: 0, width: 200, height: 200)
    #expect(CameraBubbleGeometry.isOnEdge(CGPoint(x: 199, y: 100), of: frame))
    #expect(CameraBubbleGeometry.isOnEdge(CGPoint(x: 100, y: 13), of: frame), "13 pt in from the bottom edge")
    #expect(!CameraBubbleGeometry.isOnEdge(CGPoint(x: 100, y: 100), of: frame), "the middle moves the bubble")
    #expect(!CameraBubbleGeometry.isOnEdge(CGPoint(x: 150, y: 100), of: frame), "36 pt in from the edge moves the bubble")
    #expect(!CameraBubbleGeometry.isOnEdge(CGPoint(x: 2, y: 2), of: frame), "the square's corner is outside the circle")
}

@Test func pullingTheEdgeOutGrowsTheBubbleAroundItsCenter() {
    let frame = CGRect(x: 400, y: 300, width: 200, height: 200)
    let grown = CameraBubbleGeometry.resized(frame, grabbedAt: CGPoint(x: 595, y: 400), pointer: CGPoint(x: 625, y: 400), within: area)
    #expect(grown == CGRect(x: 370, y: 270, width: 260, height: 260))
}

@Test func pushingTheEdgeInShrinksItButNotPastTheSmallestSize() {
    let frame = CGRect(x: 400, y: 300, width: 200, height: 200)
    let shrunk = CameraBubbleGeometry.resized(frame, grabbedAt: CGPoint(x: 500, y: 495), pointer: CGPoint(x: 500, y: 475), within: area)
    #expect(shrunk.size == CGSize(width: 160, height: 160))
    let smallest = CameraBubbleGeometry.resized(frame, grabbedAt: CGPoint(x: 500, y: 495), pointer: CGPoint(x: 500, y: 400), within: area)
    #expect(smallest.size == CGSize(width: 96, height: 96))
    #expect(smallest.midX == frame.midX && smallest.midY == frame.midY)
}

@Test func growingIntoTheAreasEdgeShiftsTheBubbleBackInsideAndStopsAtTheLargestSize() {
    let corner = CameraBubbleGeometry.initialFrame(in: area)
    let grown = CameraBubbleGeometry.resized(corner, grabbedAt: CGPoint(x: corner.maxX - 2, y: corner.midY), pointer: CGPoint(x: 5000, y: corner.midY), within: area)
    #expect(grown.width == 300)
    #expect(area.contains(grown))
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
