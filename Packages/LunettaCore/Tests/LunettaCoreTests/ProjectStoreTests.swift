import Foundation
import Testing
@testable import LunettaCore

struct ProjectStoreTests {
    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ProjectStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func project(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        output: String = "/tmp/out.mp4",
        renderedAt: Date? = nil
    ) -> RecordingProject {
        RecordingProject(
            id: id,
            createdAt: createdAt,
            mode: .area,
            region: CGRect(x: 0, y: 0, width: 800, height: 600),
            windowID: nil,
            parts: [ProjectPart(screen: "part-1.screen.mp4", camera: nil, events: "part-1.events.jsonl", screenStartHostTime: 1, cameraStartHostTime: nil)],
            overlays: ProjectOverlays(clicks: true, keys: false, camera: false, clickColorHex: "#FF3B30", cameraMirrored: false),
            output: ProjectOutput(file: URL(fileURLWithPath: output), codec: .hevc, frameRate: .sixty, capsToUHD: true),
            renderedAt: renderedAt
        )
    }

    @Test func aCreatedProjectLoadsBack() throws {
        let store = ProjectStore(root: makeRoot())
        let project = project()
        let folder = try store.create(project)
        #expect(folder == store.folder(for: project.id))
        #expect(try store.load(project.id) == project)
    }

    @Test func pendingRendersAreTheUnrenderedOnesOldestFirst() throws {
        let store = ProjectStore(root: makeRoot())
        let now = Date()
        let newer = project(createdAt: now)
        let older = project(createdAt: now.addingTimeInterval(-60))
        let rendered = project(createdAt: now.addingTimeInterval(-120), renderedAt: now)
        for project in [newer, older, rendered] { try store.create(project) }
        #expect(store.pendingRenders().map(\.id) == [older.id, newer.id])
    }

    @Test func reservedOutputFilesIncludeEveryUnrenderedProject() throws {
        let store = ProjectStore(root: makeRoot())
        let first = project(output: "/tmp/saves/a.mp4")
        let second = project(output: "/tmp/saves/../saves/b.mp4")
        let rendered = project(output: "/tmp/saves/c.mp4", renderedAt: Date())
        for project in [first, second, rendered] { try store.create(project) }
        #expect(store.reservedOutputFiles() == [
            URL(fileURLWithPath: "/tmp/saves/a.mp4").standardizedFileURL,
            URL(fileURLWithPath: "/tmp/saves/b.mp4").standardizedFileURL,
        ])
    }

    @Test func anUnreadableProjectIsSkippedNotFatal() throws {
        let store = ProjectStore(root: makeRoot())
        let good = project()
        try store.create(good)
        let brokenFolder = store.folder(for: UUID())
        try FileManager.default.createDirectory(at: brokenFolder, withIntermediateDirectories: true)
        try Data("nope".utf8).write(to: brokenFolder.appendingPathComponent("project.json"))
        let strayFolder = store.folder(for: good.id).deletingLastPathComponent().appendingPathComponent("not-a-uuid")
        try FileManager.default.createDirectory(at: strayFolder, withIntermediateDirectories: true)

        #expect(store.pendingRenders().map(\.id) == [good.id])
        #expect(store.reservedOutputFiles().count == 1)
    }

    @Test func loadingAMissingProjectIsUnreadable() {
        let store = ProjectStore(root: makeRoot())
        #expect(throws: ProjectError.self) { try store.load(UUID()) }
    }

    @Test func sweepDeletesProjectsRenderedOrRecordedBeforeTheCutoff() throws {
        let store = ProjectStore(root: makeRoot())
        let now = Date()
        let cutoff = now.addingTimeInterval(-100)
        let oldRendered = project(createdAt: now.addingTimeInterval(-300), renderedAt: now.addingTimeInterval(-200))
        let freshRendered = project(createdAt: now.addingTimeInterval(-300), renderedAt: now.addingTimeInterval(-10))
        let oldUnrendered = project(createdAt: now.addingTimeInterval(-500))
        let freshUnrendered = project(createdAt: now.addingTimeInterval(-10))
        for project in [oldRendered, freshRendered, oldUnrendered, freshUnrendered] { try store.create(project) }

        #expect(Set(store.sweep(olderThan: cutoff)) == [oldRendered.id, oldUnrendered.id])
        #expect(!FileManager.default.fileExists(atPath: store.folder(for: oldRendered.id).path))
        #expect(!FileManager.default.fileExists(atPath: store.folder(for: oldUnrendered.id).path))
        #expect(try store.load(freshRendered.id) == freshRendered)
        #expect(try store.load(freshUnrendered.id) == freshUnrendered)
    }

    @Test func sweepDeletesOldFoldersThatNeverGotAProject() throws {
        let root = makeRoot()
        let store = ProjectStore(root: root)
        let now = Date()
        let cutoff = now.addingTimeInterval(-100)
        let old = now.addingTimeInterval(-200)
        let abandoned = UUID()
        let inProgress = UUID()
        for id in [abandoned, inProgress] {
            try FileManager.default.createDirectory(at: store.folder(for: id).appendingPathComponent("cursors"), withIntermediateDirectories: true)
        }
        let stray = root.appendingPathComponent("not-a-uuid", isDirectory: true)
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        let unrendered = project()
        try store.create(unrendered)
        for folder in [store.folder(for: abandoned), stray, store.folder(for: unrendered.id)] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: folder.path)
        }

        #expect(store.sweep(olderThan: cutoff) == [abandoned])
        #expect(!FileManager.default.fileExists(atPath: store.folder(for: abandoned).path))
        #expect(FileManager.default.fileExists(atPath: store.folder(for: inProgress).path))
        #expect(FileManager.default.fileExists(atPath: stray.path))
        #expect(try store.load(unrendered.id) == unrendered)
    }

    @Test func deleteRemovesTheFolder() throws {
        let store = ProjectStore(root: makeRoot())
        let project = project()
        try store.create(project)
        try store.delete(project.id)
        #expect(!FileManager.default.fileExists(atPath: store.folder(for: project.id).path))
    }

    @Test func saveOverwritesTheProject() throws {
        let store = ProjectStore(root: makeRoot())
        var project = project()
        try store.create(project)
        project.renderedAt = Date()
        try store.save(project)
        #expect(try store.load(project.id).renderedAt == project.renderedAt)
    }
}
