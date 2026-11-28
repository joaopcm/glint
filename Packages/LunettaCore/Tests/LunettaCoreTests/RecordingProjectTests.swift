import Foundation
import Testing
@testable import LunettaCore

struct RecordingProjectTests {
    private func project() -> RecordingProject {
        RecordingProject(
            id: UUID(),
            createdAt: Date(),
            mode: .window,
            region: CGRect(x: 10, y: 20, width: 800, height: 600),
            windowID: 42,
            parts: [
                ProjectPart(screen: "part-1.mov", camera: "part-1-camera.mov", events: "part-1.events", screenStartHostTime: 100.5, cameraStartHostTime: 100.7),
                ProjectPart(screen: "part-2.mov", camera: nil, events: "part-2.events", screenStartHostTime: 200.25, cameraStartHostTime: nil),
            ],
            overlays: ProjectOverlays(clicks: true, keys: false, camera: true, clickColorHex: "#FF3B30", cameraMirrored: true),
            output: ProjectOutput(file: URL(fileURLWithPath: "/tmp/out.mp4"), codec: .hevc, frameRate: .sixty, capsToUHD: true),
            renderedAt: Date()
        )
    }

    @Test func aProjectSurvivesARoundTrip() throws {
        let project = project()
        let decoded = try RecordingProject.decode(project.encoded(), file: "p.json")
        #expect(decoded == project)
    }

    @Test func aProjectThatNeverFailedLeavesTheFailureOutSoOlderFilesStillLoad() throws {
        let project = project()
        let json = String(decoding: try project.encoded(), as: UTF8.self)
        #expect(!json.contains("renderFailedAt"))
        #expect(try RecordingProject.decode(Data(json.utf8), file: "p.json").renderFailedAt == nil)

        var failed = project
        failed.renderFailedAt = Date(timeIntervalSinceReferenceDate: 1000)
        #expect(try RecordingProject.decode(failed.encoded(), file: "p.json") == failed)
    }

    @Test func aNewerSchemaSaysWhichVersionsAreInvolved() throws {
        let data = Data(#"{"schemaVersion": 2}"#.utf8)
        let error = try #require(throws: ProjectError.self) {
            try RecordingProject.decode(data, file: "p.json")
        }
        #expect(error == .unsupportedVersion(found: 2, supported: 1, file: "p.json"))
        let description = try #require(error.errorDescription)
        #expect(description.contains("2") && description.contains("1") && description.contains("p.json"))
    }

    @Test func garbageIsUnreadableAndNamesTheFile() throws {
        let error = try #require(throws: ProjectError.self) {
            try RecordingProject.decode(Data("nope".utf8), file: "p.json")
        }
        guard case .unreadable(let file, _) = error else {
            Issue.record("expected .unreadable, got \(error)")
            return
        }
        #expect(file == "p.json")
    }
}
