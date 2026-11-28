import AppKit
import AVFoundation
import LunettaCore

@MainActor
final class RawCapture {
    private struct Part {
        let number: Int
        let events: EventRecorder
        let hasCameraTake: Bool
    }

    private(set) var project: RecordingProject
    private let store: ProjectStore
    private let camera: (any CameraShowing)?
    private let folder: URL
    private var partCount = 0
    private var current: Part?

    init(store: ProjectStore, project: RecordingProject, camera: (any CameraShowing)?) throws {
        self.store = store
        self.project = project
        self.camera = camera
        folder = store.folder(for: project.id)
        try FileManager.default.createDirectory(at: cursorsFolder, withIntermediateDirectories: true)
    }

    /// Starts the part's event log and camera take, and returns where its screen file goes. `bubble` is where the camera
    /// bubble already sits, logged first so the part's log has the bubble from its start.
    func beginPart(bubble: CGRect?) throws -> URL {
        partCount += 1
        let number = partCount
        let events = EventRecorder(
            writer: try CaptureEventWriter(file: file(number, .events)),
            cursors: CursorImageStore(folder: cursorsFolder),
            windowID: project.windowID
        )
        events.start()
        if let bubble { events.logBubble(bubble) }
        var hasCameraTake = false
        if let camera {
            do {
                try camera.startTake(to: file(number, .camera))
                hasCameraTake = true
            } catch {
                try? events.stop()
                removeFiles(of: number)
                throw error
            }
        }
        current = Part(number: number, events: events, hasCameraTake: hasCameraTake)
        return file(number, .screen)
    }

    /// The screen recording of the part just begun never started; its start error is the one to report.
    func abandonPart() async {
        guard let part = current else { return }
        current = nil
        if part.hasCameraTake { _ = try? await camera?.endTake() }
        try? part.events.stop()
        removeFiles(of: part.number)
    }

    func endPart(screenStartHostTime: Double?) async -> (any Error)? {
        guard let part = current else { return nil }
        current = nil
        var take: CameraTake?
        var failure: (any Error)?
        if part.hasCameraTake, let camera {
            do {
                take = try await camera.endTake()
            } catch {
                failure = error
            }
        }
        do {
            try part.events.stop()
        } catch {
            failure = failure ?? error
        }
        guard let screenStartHostTime, FileManager.default.fileExists(atPath: file(part.number, .screen).path) else {
            removeFiles(of: part.number)
            return nil
        }
        if take == nil { try? FileManager.default.removeItem(at: file(part.number, .camera)) }
        project.parts.append(ProjectPart(
            screen: name(part.number, .screen),
            camera: take == nil ? nil : name(part.number, .camera),
            events: name(part.number, .events),
            screenStartHostTime: screenStartHostTime,
            cameraStartHostTime: take?.startHostTime
        ))
        // Only for recovering a recording after a crash: finish() saves again and reports its own failure.
        try? store.save(project)
        return failure
    }

    func logKey(_ label: String) {
        current?.events.logKey(label)
    }

    func logBubble(_ frame: CGRect) {
        current?.events.logBubble(frame)
    }

    /// Saves the project so a render can pick it up; nil, with the folder gone, when no part got a frame.
    func finish() throws -> RecordingProject? {
        guard !project.parts.isEmpty else {
            try discard()
            return nil
        }
        try store.save(project)
        return project
    }

    func discard() throws {
        try store.delete(project.id)
    }

    func firstFrame(maxPixelSize: CGFloat) async -> CGImage? {
        guard let first = project.parts.first else { return nil }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: folder.appending(path: first.screen)))
        generator.appliesPreferredTrackTransform = true
        guard let image = try? await generator.image(at: .zero).image else { return nil }
        return ThumbnailDownsampler.downsample(image, maxPixelSize: maxPixelSize, keepsWholeFrame: true)
    }

    nonisolated static func accentColorHex() -> String {
        let color = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        let channels = [color.redComponent, color.greenComponent, color.blueComponent].map { Int(($0 * 255).rounded()) }
        return String(format: "#%02X%02X%02X", channels[0], channels[1], channels[2])
    }

    private enum Kind: String {
        case screen = "screen.mp4"
        case camera = "camera.mov"
        case events = "events.jsonl"
    }

    private var cursorsFolder: URL {
        folder.appending(path: "cursors", directoryHint: .isDirectory)
    }

    private func name(_ number: Int, _ kind: Kind) -> String {
        "part-\(number).\(kind.rawValue)"
    }

    private func file(_ number: Int, _ kind: Kind) -> URL {
        folder.appending(path: name(number, kind))
    }

    private func removeFiles(of number: Int) {
        for kind in [Kind.screen, .camera, .events] {
            try? FileManager.default.removeItem(at: file(number, kind))
        }
    }
}
