import AVFoundation
import Foundation
import LunettaCapture
import LunettaCore
import LunettaStudio
import Synchronization
import Testing
@testable import Lunetta

private struct Broke: LocalizedError {
    var errorDescription: String? { "The disk is full." }
}

@MainActor private final class Watch {
    var job: RenderJob?
    var log: [String] = []
    var phases: [RenderPhase] = []

    func notePhase() {
        if let job { phases.append(job.phase) }
    }
}

@MainActor private struct Projects {
    let root = FileManager.default.temporaryDirectory.appending(path: "LunettaRenderQueue-\(UUID().uuidString)")
    var store: ProjectStore { ProjectStore(root: root.appending(path: "Projects")) }
    let settings = LunettaSettings(store: Defaults(), defaultSaveFolder: FileManager.default.temporaryDirectory)

    func make(name: String, createdAt: Date = Date(), renderedAt: Date? = nil) throws -> RecordingProject {
        let project = RecordingProject(
            id: UUID(),
            createdAt: createdAt,
            mode: .area,
            region: CGRect(x: 0, y: 0, width: 64, height: 48),
            windowID: nil,
            parts: [ProjectPart(screen: "part-1.screen.mp4", camera: nil, events: "part-1.events.jsonl", screenStartHostTime: 1000, cameraStartHostTime: nil)],
            overlays: ProjectOverlays(clicks: false, keys: false, camera: false, clickColorHex: "#FF0000", cameraMirrored: false),
            output: ProjectOutput(file: root.appending(path: "saved/\(name).mp4"), codec: .h264, frameRate: .thirty, capsToUHD: true),
            renderedAt: renderedAt
        )
        try store.create(project)
        return project
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor @Test func jobsRunOneAtATimeInOrder() async throws {
    let projects = Projects()
    defer { projects.remove() }
    let first = try projects.make(name: "First")
    let second = try projects.make(name: "Second")
    let watch = Watch()
    let queue = RenderQueue(store: projects.store, settings: projects.settings, render: { folder, _ in
        let name = folder.lastPathComponent == first.id.uuidString ? "first" : "second"
        watch.log.append("start \(name)")
        try await Task.sleep(for: .milliseconds(50))
        watch.log.append("end \(name)")
    })

    let firstJob = queue.enqueue(first)
    let secondJob = queue.enqueue(second)
    await secondJob.finished()

    #expect(watch.log == ["start first", "end first", "start second", "end second"])
    #expect(firstJob.phase == .done(nil))
    #expect(secondJob.phase == .done(nil))
}

@MainActor @Test func successMarksTheProjectRenderedThenCompressesWhenOn() async throws {
    let projects = Projects()
    defer { projects.remove() }
    projects.settings.compressAfterCapture = true
    let project = try projects.make(name: "Recording")
    let store = projects.store
    let watch = Watch()
    let compressed = CompressionResult(originalBytes: 1000, compressedBytes: 400)
    let queue = RenderQueue(
        store: store,
        settings: projects.settings,
        render: { _, progress in
            progress(0.5)
            try await Task.sleep(for: .milliseconds(50))
            watch.notePhase()
        },
        compress: { file in
            let renderedFirst = (try? store.load(project.id))?.renderedAt != nil
            await MainActor.run {
                watch.notePhase()
                watch.log.append("compress \(file.lastPathComponent), rendered first: \(renderedFirst)")
            }
            return compressed
        }
    )

    let job = queue.enqueue(project)
    watch.job = job
    watch.notePhase()
    await job.finished()
    watch.notePhase()

    #expect(watch.phases == [.queued, .rendering(0.5), .compressing, .done(compressed)])
    #expect(watch.log == ["compress Recording.mp4, rendered first: true"])
    #expect(try store.load(project.id).renderedAt != nil)
    #expect(store.pendingRenders().isEmpty)
}

@MainActor @Test func aCompressionFailureKeepsTheRenderedVideoAndSaysWhy() async throws {
    let projects = Projects()
    defer { projects.remove() }
    projects.settings.compressAfterCapture = true
    let project = try projects.make(name: "Recording")
    let queue = RenderQueue(
        store: projects.store,
        settings: projects.settings,
        render: { _, _ in },
        compress: { _ in throw Broke() }
    )

    let job = queue.enqueue(project)
    await job.finished()

    #expect(job.phase == .done(nil))
    #expect(job.compressionFailure == "The disk is full.")
    #expect(try projects.store.load(project.id).renderedAt != nil)
    #expect(projects.store.pendingRenders().isEmpty)
}

@MainActor @Test func aFailureSaysWhyAndRetryRunsAgain() async throws {
    let projects = Projects()
    defer { projects.remove() }
    let project = try projects.make(name: "Recording")
    let watch = Watch()
    let queue = RenderQueue(store: projects.store, settings: projects.settings, render: { _, _ in
        watch.log.append("render")
        if watch.log.count == 1 { throw Broke() }
    })

    let job = queue.enqueue(project)
    await job.finished()
    #expect(job.phase == .failed("The disk is full."))
    #expect(projects.store.pendingRenders().map(\.id) == [project.id])

    job.retry()
    #expect(job.phase == .queued)
    await job.finished()
    #expect(job.phase == .done(nil))
    #expect(watch.log == ["render", "render"])
    #expect(projects.store.pendingRenders().isEmpty)
}

@MainActor @Test func aFinishedRenderNamesItsRecording() async throws {
    let projects = Projects()
    defer { projects.remove() }
    let project = try projects.make(name: "Demo")
    let watch = Watch()
    let queue = RenderQueue(store: projects.store, settings: projects.settings, render: { _, _ in
        watch.log.append("render")
        if watch.log.count == 1 { throw Broke() }
    })

    let job = queue.enqueue(project)
    await job.finished()
    #expect(job.outcomeMessage == "Couldn't render Demo.mp4: The disk is full.")

    job.retry()
    await job.finished()
    #expect(job.outcomeMessage == "Rendered Demo.mp4")
}

@MainActor @Test func pendingProjectsRenderAgainAtLaunch() async throws {
    let projects = Projects()
    defer { projects.remove() }
    let pending = try projects.make(name: "Pending")
    _ = try projects.make(name: "Done", renderedAt: Date())
    let watch = Watch()
    let queue = RenderQueue(store: projects.store, settings: projects.settings, render: { folder, _ in
        watch.log.append(folder.lastPathComponent)
    })

    let jobs = queue.resumePending()
    #expect(jobs.map(\.project.id) == [pending.id])
    for job in jobs { await job.finished() }

    #expect(watch.log == [pending.id.uuidString])
    #expect(projects.store.pendingRenders().isEmpty)
}

@MainActor @Test func aCancelledRenderStaysPendingWithoutFailing() async throws {
    let projects = Projects()
    defer { projects.remove() }
    let cancelled = try projects.make(name: "Cancelled")
    let next = try projects.make(name: "Next")
    let queue = RenderQueue(store: projects.store, settings: projects.settings, render: { folder, _ in
        if folder.lastPathComponent == cancelled.id.uuidString { throw CancellationError() }
    })

    let cancelledJob = queue.enqueue(cancelled)
    let nextJob = queue.enqueue(next)
    await nextJob.finished()

    #expect(cancelledJob.phase == .queued)
    #expect(nextJob.phase == .done(nil))
    #expect(projects.store.pendingRenders().map(\.id) == [cancelled.id])
}

/// One at a time: every test talks to the same service process, and one of them kills it.
@MainActor @Suite(.serialized) struct RenderServiceTests {
    @Test func rendersAProjectOutOfProcess() async throws {
        let projects = Projects()
        defer { projects.remove() }
        let (project, folder) = try await renderableProject(in: projects, seconds: 1)
        let sent = Mutex<[Double]>([])

        try await RenderQueue.renderInService(folder) { fraction in sent.withLock { $0.append(fraction) } }

        let duration = try await AVURLAsset(url: project.output.file).load(.duration)
        #expect(abs(duration.seconds - 1) < 0.1)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "render.partial.mp4").path))
        let fractions = sent.withLock { $0 }
        #expect(fractions.last == 1)
        #expect(Set(fractions.map { Int(($0 * 100).rounded(.down)) }).count == fractions.count)
    }

    @Test func saysWhyAProjectCantRender() async throws {
        let projects = Projects()
        defer { projects.remove() }
        let project = try projects.make(name: "Recording")

        let error = await #expect(throws: (any Error).self) {
            try await RenderQueue.renderInService(projects.store.folder(for: project.id)) { _ in }
        }

        #expect(error?.localizedDescription == RenderError.missingMedia(file: "part-1.screen.mp4").errorDescription)
    }

    @Test func aServiceThatQuitsMidRenderFailsTheRenderAndLeavesNoVideo() async throws {
        let projects = Projects()
        defer { projects.remove() }
        let (project, folder) = try await renderableProject(in: projects, seconds: 10)
        let service = Bundle.main.bundleURL.appending(path: "Contents/XPCServices/LunettaRenderService.xpc/Contents/MacOS/LunettaRenderService")
        let killed = Mutex(false)

        await #expect(throws: RenderServiceError.serviceQuit) {
            try await RenderQueue.renderInService(folder) { _ in
                guard !killed.withLock({ defer { $0 = true }; return $0 }) else { return }
                let pkill = Process()
                pkill.executableURL = URL(filePath: "/usr/bin/pkill")
                pkill.arguments = ["-9", "-f", service.path]
                try? pkill.run()
            }
        }

        #expect(killed.withLock { $0 })
        #expect(!FileManager.default.fileExists(atPath: project.output.file.path))
    }

    private func renderableProject(in projects: Projects, seconds: Int) async throws -> (RecordingProject, URL) {
        let project = try projects.make(name: "Recording")
        let folder = projects.store.folder(for: project.id)
        try FileManager.default.createDirectory(at: project.output.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await writeScreen(to: folder.appending(path: project.parts[0].screen), seconds: seconds)
        try Data().write(to: folder.appending(path: project.parts[0].events))
        return (project, folder)
    }
}

/// Gray at 30 fps, like a raw screen part without audio.
private func writeScreen(to url: URL, seconds: Int) async throws {
    let fps: Int32 = 30
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 48,
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: 64,
        kCVPixelBufferHeightKey as String: 48,
    ])
    writer.add(video)
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<Int(fps) * seconds {
        while !video.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, try #require(adaptor.pixelBufferPool), &buffer)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(CVPixelBufferGetBaseAddress(pixels), 128, CVPixelBufferGetDataSize(pixels))
        CVPixelBufferUnlockBaseAddress(pixels, [])
        #expect(adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps)))
    }
    video.markAsFinished()
    writer.endSession(atSourceTime: CMTime(value: CMTimeValue(Int(fps) * seconds), timescale: fps))
    await writer.finishWriting()
    #expect(writer.status == .completed, "\(writer.error?.localizedDescription ?? "")")
}
