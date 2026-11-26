import Foundation
import Testing
@testable import LunettaCore

private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
private let area = CGRect(x: 100, y: 200, width: 400, height: 300)

@Test func pressesOnAGripResizeInsideMoveAndOutsideDraw() {
    #expect(StageGeometry.drag(startingAt: CGPoint(x: 505, y: 195), on: area) == .resize(.bottomRight, from: area))
    #expect(StageGeometry.drag(startingAt: CGPoint(x: 300, y: 502), on: area) == .resize(.top, from: area))
    #expect(StageGeometry.drag(startingAt: CGPoint(x: 300, y: 350), on: area) == .move(from: area, grab: CGPoint(x: 300, y: 350)))
    #expect(StageGeometry.drag(startingAt: CGPoint(x: 900, y: 900), on: area) == .draw(from: CGPoint(x: 900, y: 900)))
}

@Test func theNearestGripWinsOnATinyArea() {
    let tiny = CGRect(x: 100, y: 100, width: 10, height: 10)
    #expect(StageGeometry.handle(at: CGPoint(x: 99, y: 111), on: tiny) == .topLeft)
    #expect(StageGeometry.handle(at: CGPoint(x: 111, y: 99), on: tiny) == .bottomRight)
}

@Test func aGripResizesFromTheOppositeCornerOrEdge() {
    let corner = StageGeometry.rect(for: .resize(.bottomRight, from: area), pointer: CGPoint(x: 550, y: 170), bounds: screen)
    #expect(corner == CGRect(x: 100, y: 170, width: 450, height: 330))
    let edge = StageGeometry.rect(for: .resize(.left, from: area), pointer: CGPoint(x: 60, y: 900), bounds: screen)
    #expect(edge == CGRect(x: 60, y: 200, width: 440, height: 300), "an edge grip only moves its own edge")
}

@Test func draggingAGripPastTheOppositeEdgeFlipsTheArea() {
    let flipped = StageGeometry.rect(for: .resize(.right, from: area), pointer: CGPoint(x: 50, y: 0), bounds: screen)
    #expect(flipped == CGRect(x: 50, y: 200, width: 50, height: 300))
}

@Test func movingFollowsTheGrabAndStaysOnScreen() {
    let grab = CGPoint(x: 300, y: 350)
    #expect(StageGeometry.rect(for: .move(from: area, grab: grab), pointer: CGPoint(x: 320, y: 340), bounds: screen)
        == CGRect(x: 120, y: 190, width: 400, height: 300))
    #expect(StageGeometry.rect(for: .move(from: area, grab: grab), pointer: CGPoint(x: 5000, y: -5000), bounds: screen)
        == CGRect(x: 1112, y: 0, width: 400, height: 300))
}

@Test func drawingAndResizingStopAtTheScreenEdge() {
    #expect(StageGeometry.rect(for: .draw(from: CGPoint(x: 1400, y: 100)), pointer: CGPoint(x: 1700, y: -40), bounds: screen)
        == CGRect(x: 1400, y: 0, width: 112, height: 100))
    #expect(StageGeometry.rect(for: .resize(.topLeft, from: area), pointer: CGPoint(x: -30, y: 2000), bounds: screen)
        == CGRect(x: 0, y: 200, width: 500, height: 782))
}

@Test func nudgingMovesByTheOffsetButNotOffScreen() {
    #expect(StageGeometry.nudge(area, by: CGPoint(x: 10, y: -1), in: screen) == CGRect(x: 110, y: 199, width: 400, height: 300))
    #expect(StageGeometry.nudge(CGRect(x: 0, y: 0, width: 50, height: 50), by: CGPoint(x: -1, y: -1), in: screen).origin == .zero)
}

@Test func theNoticeSitsOnTheFarSideOfTheToolbarFromTheArea() {
    let size = CGSize(width: 300, height: 60)
    let toolbarBelow = CGRect(x: 200, y: 156, width: 200, height: 32)
    #expect(StageGeometry.noticeFrame(size: size, toolbar: toolbarBelow, region: area, visible: screen, gap: 8).maxY == 148)

    let low = CGRect(x: 100, y: 60, width: 400, height: 300)
    let toolbarJustBelowLow = CGRect(x: 200, y: 16, width: 200, height: 32)
    #expect(StageGeometry.noticeFrame(size: size, toolbar: toolbarJustBelowLow, region: low, visible: screen, gap: 8).minY == 56,
            "no room below the toolbar, so the notice goes between it and the area")

    let toolbarAbove = CGRect(x: 200, y: 512, width: 200, height: 32)
    #expect(StageGeometry.noticeFrame(size: size, toolbar: toolbarAbove, region: area, visible: screen, gap: 8).minY == 552)
}
