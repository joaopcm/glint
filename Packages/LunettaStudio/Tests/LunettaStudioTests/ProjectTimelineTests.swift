import Foundation
import LunettaCore
import Testing
@testable import LunettaStudio

private func project(screenStarts: [Double]) -> RecordingProject {
    RecordingProject(
        id: UUID(),
        createdAt: Date(),
        mode: .area,
        region: CGRect(x: 0, y: 0, width: 400, height: 300),
        windowID: nil,
        parts: screenStarts.enumerated().map { index, start in
            ProjectPart(screen: "part-\(index + 1).screen.mp4", camera: nil, events: "part-\(index + 1).events.jsonl", screenStartHostTime: start, cameraStartHostTime: nil)
        },
        overlays: ProjectOverlays(clicks: false, keys: false, camera: false, clickColorHex: "#007AFF", cameraMirrored: true),
        output: ProjectOutput(file: URL(fileURLWithPath: "/tmp/out.mp4"), codec: .h264, frameRate: .thirty, capsToUHD: true)
    )
}

@Test func timeCrossesIntoTheNextPartAtItsBoundary() {
    let timeline = ProjectTimeline(project: project(screenStarts: [100, 500]), partDurations: [2, 3])

    #expect(timeline.duration == 5)

    let beforeBoundary = timeline.locate(1.5)
    #expect(beforeBoundary.part == 0)
    #expect(beforeBoundary.partTime == 1.5)
    #expect(beforeBoundary.hostTime == 101.5)

    let atBoundary = timeline.locate(2)
    #expect(atBoundary.part == 1)
    #expect(atBoundary.partTime == 0)
    #expect(atBoundary.hostTime == 500)

    let inSecondPart = timeline.locate(4)
    #expect(inSecondPart.part == 1)
    #expect(inSecondPart.partTime == 2)
    #expect(inSecondPart.hostTime == 502)
}
