import Foundation
import Testing
@testable import LunettaCore

@Test func evenRegionKeepsEvenSizes() throws {
    let region = try #require(RecordingGeometry.evenPixelRegion(of: CGRect(x: 10, y: 20, width: 200, height: 150), scale: 2))
    #expect(region.width == 400 && region.height == 300)
    #expect(region.sourceRect == CGRect(x: 10, y: 20, width: 200, height: 150))
}

@Test func evenRegionTrimsTheOddPixelFromTheRightAndBottom() throws {
    let region = try #require(RecordingGeometry.evenPixelRegion(of: CGRect(x: 10, y: 20, width: 201, height: 151), scale: 1))
    #expect(region.width == 200 && region.height == 150)
    #expect(region.sourceRect == CGRect(x: 10, y: 20, width: 200, height: 150))
}

@Test func evenRegionTrimsHalfPointsOnRetina() throws {
    let region = try #require(RecordingGeometry.evenPixelRegion(of: CGRect(x: 0, y: 0, width: 100.5, height: 50.5), scale: 2))
    #expect(region.width == 200 && region.height == 100)
    #expect(region.sourceRect.size == CGSize(width: 100, height: 50))
}

@Test func evenRegionRejectsSlivers() {
    #expect(RecordingGeometry.evenPixelRegion(of: CGRect(x: 0, y: 0, width: 1, height: 300), scale: 1) == nil)
}

private let screen = CGRect(x: 0, y: 0, width: 1512, height: 944)
private let bar = CGSize(width: 220, height: 64)

@Test func controlsSitCenteredUnderTheRegion() {
    let frame = RecordingGeometry.controlBarFrame(size: bar, region: CGRect(x: 400, y: 300, width: 600, height: 400), visible: screen, gap: 12)
    #expect(frame == CGRect(x: 590, y: 224, width: 220, height: 64))
}

@Test func controlsMoveAboveARegionThatReachesTheBottom() {
    let frame = RecordingGeometry.controlBarFrame(size: bar, region: CGRect(x: 400, y: 20, width: 600, height: 400), visible: screen, gap: 12)
    #expect(frame.minY == 432)
}

@Test func controlsGoInsideTheBottomOfAFullScreenRegion() {
    let frame = RecordingGeometry.controlBarFrame(size: bar, region: screen, visible: screen, gap: 12)
    #expect(frame.minY == 12)
    #expect(frame.midX == screen.midX)
}

@Test func controlsStayOnScreenUnderARegionAtTheEdge() {
    let frame = RecordingGeometry.controlBarFrame(size: bar, region: CGRect(x: 1400, y: 300, width: 100, height: 100), visible: screen, gap: 12)
    #expect(frame.maxX == screen.maxX - 12)
}

@Test func controlsFollowAScreenThatIsNotAtTheOrigin() {
    let left = CGRect(x: -1920, y: -200, width: 1920, height: 1055)
    let frame = RecordingGeometry.controlBarFrame(size: bar, region: CGRect(x: -1000, y: 300, width: 200, height: 200), visible: left, gap: 12)
    #expect(frame == CGRect(x: -1010, y: 224, width: 220, height: 64))
}

@Test func countdownSitsInTheMiddleOfTheRegion() {
    let center = RecordingGeometry.countdownCenter(size: CGSize(width: 120, height: 160), region: CGRect(x: 100, y: 100, width: 400, height: 200), visible: screen)
    #expect(center == CGPoint(x: 300, y: 200))
}

@Test func countdownStaysOnScreenForATinyRegionInTheCorner() {
    let center = RecordingGeometry.countdownCenter(size: CGSize(width: 120, height: 160), region: CGRect(x: 0, y: 0, width: 40, height: 40), visible: screen)
    #expect(center == CGPoint(x: 60, y: 80))
}
