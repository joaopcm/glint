import Foundation
import Testing
@testable import GlintCore

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

@Test func borderSurroundsTheRegionWithoutCoveringIt() {
    let region = CGRect(x: 100, y: 200, width: 300, height: 150)
    let border = RecordingGeometry.borderFrame(around: region, lineWidth: 2)
    #expect(border == CGRect(x: 98, y: 198, width: 304, height: 154))
    #expect(border.insetBy(dx: 2, dy: 2) == region)
}
