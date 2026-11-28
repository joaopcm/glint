import AppKit
import LunettaCapture
import LunettaCore

enum CaptureMode {
    case area, window, fullScreen, scrolling
}

enum SelectionResult: Equatable {
    case area(CGRect)
    case window(UInt32)
    case cancelled
}

protocol Capturing: Sendable {
    func hasPermission() async -> Bool
    func displays() async -> [DisplayInfo]
    func captureArea(_ selection: CGRect, displays: [DisplayInfo]) async throws -> CGImage
    func captureDisplay(_ display: DisplayInfo) async throws -> CGImage
    func captureWindow(id: UInt32, wallpaperPadding: Double?) async throws -> CGImage
    func shareableWindows() async throws -> [CapturableWindow]
    func scrollingFrames(of selection: CGRect, displays: [DisplayInfo]) async throws -> ScrollingFrames
}

protocol Recording: Sendable {
    func startRecording(_ target: RecordingTarget, to url: URL, options: RecordingOptions) async throws -> any ActiveRecording
    func join(_ parts: [URL], into url: URL) async throws
}

struct RecordingStatus: Equatable {
    let region: CGRect
    /// Area recordings only: a window recording follows its window around, and a fixed cut-out would not.
    let dimsOutside: Bool
    var clock = RecordingClock()
}

enum RecordingEnd: Equatable {
    case saved, discarded, failed
}

enum RecordingEvent: Equatable {
    case started(RecordingStatus)
    case paused(RecordingStatus)
    case resumed(RecordingStatus)
    case ended(RecordingEnd)
}

@MainActor
protocol MicrophoneAccess {
    var status: DeviceAccess { get }
    var inputs: [AudioInput] { get }
    func requestAccess() async -> Bool
    func openSettings()
}

/// The pressed keys drawn over a recorded area, and the Input Monitoring access reading them needs.
@MainActor
protocol KeystrokeShowing {
    var isAllowed: Bool { get }
    func show(over region: CGRect) throws
    func hide()
    func openSettings()
}

/// The camera bubble shown in a recorded area, and the Camera access it needs. `camera` nil shows the system's camera.
@MainActor
protocol CameraShowing {
    var access: DeviceAccess { get }
    var cameras: [CameraInput] { get }
    func requestAccess() async -> Bool
    func openSettings()
    func show(over region: CGRect, camera: CameraInput?) throws
    func hide()
}

/// The rings drawn under the pointer on each click in a recorded area.
@MainActor
protocol ClickShowing {
    func show(over region: CGRect)
    func hide()
}

/// What Lunetta draws over a recorded area for the video to show.
private struct RecordingOverlays {
    var keys = false
    var clicks = false
    var camera = false
    var cameraInput: CameraInput?
}

enum ScrollStageDecision: Equatable {
    case done, cancelled
}

/// The stage around a scrolling capture. It closes itself once `decision()` resolves, and ignores `show` after that.
@MainActor
protocol ScrollStaging {
    /// The height of the stage's preview strip, in pixels of the captured area.
    var previewPixelHeight: Int { get }
    /// Puts the stage's windows on screen and registers its hotkeys.
    func prepare(_ area: CGRect, on display: DisplayInfo)
    /// Resolves once: Done/Return or Cancel/Esc.
    func decision() async -> ScrollStageDecision
    func show(_ update: StitchUpdate, preview: CGImage?)
    /// Closes the stage when the stream fails, resolving a pending `decision()` with `.cancelled`; a closed stage stays closed.
    func dismiss()
}

@MainActor
protocol RecordingStaging {
    /// Shows `region` to record with the panel's choices, and to move and resize first when it's an area; nil when the
    /// user drops it. A window's region comes back as it went in.
    func stage(_ region: CGRect, on display: DisplayInfo, mode: RecordingMode) async -> CGRect?
}

protocol ActiveRecording: Sendable {
    func stop() async
    func finished() async throws
}

/// A capture being compressed in place; nil when it came out no smaller and the saved file stays.
typealias PendingCompression = Task<CompressionResult?, any Error>

private struct SavedScreenshot: Sendable {
    let url: URL
    let png: Data
    let compression: PendingCompression?
}

struct FrozenDisplay: Sendable {
    let display: DisplayInfo
    let image: CGImage
}

@MainActor
protocol Selecting {
    /// `frozen` is empty for a live overlay; otherwise it holds one grab per display, shown under the selection.
    func selectArea(frozen: [FrozenDisplay]) async throws -> SelectionResult
    func selectWindow(_ windows: Task<[CapturableWindow], any Error>) async throws -> SelectionResult
}

struct CaptureAlert: Equatable {
    enum Button: String {
        case ok = "OK"
        case openSystemSettings = "Open System Settings"
        case allowMicrophone = "Allow Microphone"
        case openMicrophoneSettings = "Open Microphone Settings"
        case allowCamera = "Allow Camera"
        case openCameraSettings = "Open Camera Settings"
        case openInputMonitoringSettings = "Open Input Monitoring Settings"

        init(_ fix: RecordingFix) {
            self = switch fix {
            case .allowMicrophone: .allowMicrophone
            case .openMicrophoneSettings: .openMicrophoneSettings
            case .allowCamera: .allowCamera
            case .openCameraSettings: .openCameraSettings
            case .openInputMonitoringSettings: .openInputMonitoringSettings
            }
        }
    }

    let title: String
    let message: String
    let buttons: [Button]
}

@MainActor
protocol AlertPresenting {
    func present(_ alert: CaptureAlert) -> CaptureAlert.Button
}

enum CoordinatorError: LocalizedError {
    case noDisplays
    case clipboardFailed(savedTo: URL, reason: String)
    case inputDisconnected(AudioInput, savedTo: URL?)

    var errorDescription: String? {
        switch self {
        case .noDisplays:
            "No display is connected, so there is nothing to capture."
        case .clipboardFailed(let url, let reason):
            "The screenshot was saved to \(url.path), but copying it to the clipboard failed: \(reason)"
        case .inputDisconnected(let input, let url):
            InputDisconnected.message(input: input, savedTo: url?.path)
        }
    }
}

/// One recording from the first frame to the saved file: a part per stretch between pauses.
@MainActor
private final class RecordingSession {
    struct Segment {
        let recording: any ActiveRecording
        let url: URL
        let end: Task<(any Error)?, Never>
    }

    let target: RecordingTarget
    let options: RecordingOptions
    let overlays: RecordingOverlays
    /// The input chosen in the panel; nil when the microphone is off or follows the system default.
    let input: AudioInput?
    let url: URL
    let partsFolder = FileManager.default.temporaryDirectory.appending(path: "Lunetta-recording-\(UUID().uuidString)")
    var status: RecordingStatus
    var parts: [URL] = []
    var segment: Segment?
    var isEnding = false
    var lostInput: AudioInput?
    private var partCount = 0
    private var queue: Task<Void, Never>?

    init(target: RecordingTarget, options: RecordingOptions, overlays: RecordingOverlays, input: AudioInput?, url: URL, status: RecordingStatus) {
        self.target = target
        self.options = options
        self.overlays = overlays
        self.input = input
        self.url = url
        self.status = status
    }

    func nextPartURL() -> URL {
        partCount += 1
        return partsFolder.appending(path: "part-\(partCount).mp4")
    }

    /// Pause, resume, stop and discard run one at a time, in the order they came in.
    func serially(_ work: @escaping @MainActor () async -> Void) async {
        let previous = queue
        let next = Task {
            await previous?.value
            await work()
        }
        queue = next
        await next.value
    }
}

@MainActor
final class CaptureCoordinator {
    private let capturer: any Capturing
    private let recorder: any Recording
    private let microphone: any MicrophoneAccess
    private let keystrokes: any KeystrokeShowing
    private let clickRings: any ClickShowing
    private let camera: any CameraShowing
    private let stager: any RecordingStaging
    private let scrollStager: any ScrollStaging
    private let selector: any Selecting
    private let alerts: any AlertPresenting
    private let settings: LunettaSettings
    private let now: () -> Date
    private let fileExists: (URL) -> Bool
    private let pointerLocation: @MainActor () -> CGPoint
    private let copyToClipboard: @MainActor (URL, Data) throws -> Void
    private let writePNG: @Sendable (CGImage, URL) async throws -> Data
    private let compress: @Sendable (URL) async throws -> CompressionResult?
    private let playShutterSound: @MainActor () -> Void
    private let onSaved: @MainActor (URL, _ thumbnail: CGImage?, PendingCompression?) -> Void
    private let onRecordingEvent: @MainActor (RecordingEvent) -> Void
    private let countDown: @MainActor (RecordingStatus) async -> Bool
    private var isRunning = false
    private var delivery: Task<SavedScreenshot?, Never>?
    private var clipboardCopy: Task<Void, Never>?
    private var session: RecordingSession?
    private var countdown: Task<Bool, Never>?
    private var scrollStageIsDeciding = false

    init(
        capturer: any Capturing,
        recorder: any Recording,
        microphone: any MicrophoneAccess,
        keystrokes: any KeystrokeShowing,
        clickRings: any ClickShowing,
        camera: any CameraShowing,
        stager: any RecordingStaging,
        scrollStager: any ScrollStaging,
        selector: any Selecting,
        alerts: any AlertPresenting,
        settings: LunettaSettings,
        now: @escaping () -> Date = Date.init,
        fileExists: @escaping (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
        pointerLocation: @escaping @MainActor () -> CGPoint = { NSEvent.mouseLocation },
        copyToClipboard: @escaping @MainActor (URL, Data) throws -> Void = { url, data in try NSPasteboard.general.copyPNGData(data, fileURL: url) },
        writePNG: @escaping @Sendable (CGImage, URL) async throws -> Data = CaptureCoordinator.writePNG,
        compress: @escaping @Sendable (URL) async throws -> CompressionResult? = CaptureCompressor.compress,
        playShutterSound: @escaping @MainActor () -> Void = {},
        onSaved: @escaping @MainActor (URL, _ thumbnail: CGImage?, PendingCompression?) -> Void = { _, _, _ in },
        onRecordingEvent: @escaping @MainActor (RecordingEvent) -> Void = { _ in },
        countDown: @escaping @MainActor (RecordingStatus) async -> Bool = { _ in true }
    ) {
        self.capturer = capturer
        self.recorder = recorder
        self.microphone = microphone
        self.keystrokes = keystrokes
        self.clickRings = clickRings
        self.camera = camera
        self.stager = stager
        self.scrollStager = scrollStager
        self.selector = selector
        self.alerts = alerts
        self.settings = settings
        self.now = now
        self.fileExists = fileExists
        self.pointerLocation = pointerLocation
        self.copyToClipboard = copyToClipboard
        self.writePNG = writePNG
        self.compress = compress
        self.playShutterSound = playShutterSound
        self.onSaved = onSaved
        self.onRecordingEvent = onRecordingEvent
        self.countDown = countDown
    }

    /// Only taking the image blocks the next capture (#99); saves queue so each one names its file after the ones before it
    /// are on disk. Copying waits for compression outside that queue, so a compressing capture never holds up the next card.
    func run(_ mode: CaptureMode) async {
        guard let image = await captureImage(mode) else { return }
        let previous = delivery
        let saving = Task { () async -> SavedScreenshot? in
            _ = await previous?.value
            do {
                return try await save(image)
            } catch {
                present(error)
                return nil
            }
        }
        delivery = saving
        guard let saved = await saving.value else { return }
        await copyIfOn(saved)
    }

    func captureImage(_ mode: CaptureMode) async -> CGImage? {
        guard !isRunning else { return nil }
        isRunning = true
        defer { isRunning = false }
        guard let image = await takeImage(mode) else { return nil }
        if settings.playSoundOnCapture { playShutterSound() }
        return image
    }

    private func takeImage(_ mode: CaptureMode) async -> CGImage? {
        do {
            guard await capturer.hasPermission() else { throw CaptureError.permissionDenied }
            return try await selectAndCapture(mode)
        } catch {
            present(error)
            return nil
        }
    }

    /// The record hotkeys toggle: during the countdown they cancel it, while recording they stop. The picked area or
    /// window goes on the stage first, where the choices are set and any missing permission is shown instead of alerted.
    func toggleRecording(_ mode: RecordingMode) async {
        if let countdown {
            countdown.cancel()
            return
        }
        guard session == nil else { return await stopRecording() }
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        var selected = false
        var overlays = RecordingOverlays()
        defer { if session == nil { hide(overlays) } }
        do {
            guard await capturer.hasPermission() else { throw CaptureError.permissionDenied }
            guard let picked = try await selectRecordingTarget(mode) else { return }
            guard let region = await stager.stage(picked.region, on: picked.display, mode: mode) else { return }
            if let problem = recordingProblems().first { throw problem }
            let choices = settings.recordingChoices
            // Following a window holds that window alone, so the camera and pressed keys only reach it recorded in place.
            let target: RecordingTarget = switch picked.target {
            case .area: .area(region, on: picked.display)
            case .window(let id) where choices.camera || choices.showsKeys: .windowInPlace(id, frame: region, on: picked.display)
            case .window, .windowInPlace: picked.target
            }
            let followsWindow = switch target {
            case .window: true
            case .area, .windowInPlace: false
            }
            selected = true
            let input = choices.microphone ? choices.input : nil
            // A followed window is recorded alone, so Lunetta's rings can't reach it and macOS's circles stand in.
            let drawsClicks = choices.showsClicks && !followsWindow
            let options = RecordingOptions(
                codec: settings.recordingCodec,
                frameRate: settings.recordingFrameRate,
                systemAudio: choices.systemAudio,
                microphone: choices.microphone,
                microphoneID: input?.id,
                showsClicks: choices.showsClicks && !drawsClicks
            )
            overlays = RecordingOverlays(
                keys: choices.showsKeys,
                clicks: drawsClicks,
                camera: choices.camera,
                cameraInput: choices.camera ? choices.cameraInput : nil
            )
            try show(overlays, over: region)
            let status = RecordingStatus(region: region, dimsOutside: mode == .area)
            try await record(target, status: status, options: options, overlays: overlays, input: input)
        } catch {
            if selected { onRecordingEvent(.ended(.failed)) }
            present(error, failure: "Lunetta couldn't start the recording")
        }
    }

    func startOverRecording() async {
        guard let session, !session.isEnding, !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        await discardRecording()
        let overlays = session.overlays
        defer { if self.session == nil { hide(overlays) } }
        do {
            // Discarding took the overlays down with the old recording; the new one gets them back.
            try show(overlays, over: session.status.region)
            let status = RecordingStatus(region: session.status.region, dimsOutside: session.status.dimsOutside)
            try await record(session.target, status: status, options: session.options, overlays: overlays, input: session.input)
        } catch {
            onRecordingEvent(.ended(.failed))
            present(error, failure: "Lunetta couldn't start the recording over")
        }
    }

    private func show(_ overlays: RecordingOverlays, over region: CGRect) throws {
        if overlays.keys { try keystrokes.show(over: region) }
        if overlays.clicks { clickRings.show(over: region) }
        if overlays.camera { try camera.show(over: region, camera: overlays.cameraInput) }
    }

    private func hide(_ overlays: RecordingOverlays) {
        if overlays.keys { keystrokes.hide() }
        if overlays.clicks { clickRings.hide() }
        if overlays.camera { camera.hide() }
    }

    private func record(
        _ target: RecordingTarget,
        status: RecordingStatus,
        options: RecordingOptions,
        overlays: RecordingOverlays,
        input: AudioInput?
    ) async throws {
        guard await countDownIfOn(status) else { return }
        let url = nextFileURL(ext: "mp4")
        var status = status
        status.clock.start(at: now())
        // The HUD has to be on screen before the stream starts, or the recording can't tell to leave it out.
        onRecordingEvent(.started(status))
        let active = try await recorder.startRecording(target, to: url, options: options)
        let session = RecordingSession(target: target, options: options, overlays: overlays, input: input, url: url, status: status)
        self.session = session
        attach(active, writingTo: url, in: session)
    }

    private func countDownIfOn(_ status: RecordingStatus) async -> Bool {
        guard settings.recordingCountdown else { return true }
        let counting = Task { await countDown(status) }
        countdown = counting
        defer { countdown = nil }
        return await counting.value
    }

    /// What keeps the panel's current choices from recording; checked again once the stage hands over.
    func recordingProblems() -> [RecordingProblem] {
        RecordingPreflight.problems(
            choices: settings.recordingChoices,
            microphone: microphone.status,
            camera: camera.access,
            inputMonitoringAllowed: keystrokes.isAllowed,
            connectedInputs: settings.recordMicrophone ? microphone.inputs : [],
            connectedCameras: settings.recordCamera ? camera.cameras : []
        )
    }

    func fix(_ fix: RecordingFix) async {
        switch fix {
        case .allowMicrophone: _ = await microphone.requestAccess()
        case .openMicrophoneSettings: microphone.openSettings()
        case .allowCamera: _ = await camera.requestAccess()
        case .openCameraSettings: camera.openSettings()
        case .openInputMonitoringSettings: keystrokes.openSettings()
        }
    }

    /// SCStream keeps recording when its input goes away; ending here keeps the file from going on without its sound.
    func inputDisconnected(id: String) async {
        guard let session, !session.isEnding, let input = session.input, input.id == id else { return }
        session.lostInput = input
        await end(session)
    }

    func stopRecording() async {
        guard let session, !session.isEnding else { return }
        await end(session)
    }

    func togglePause() async {
        guard let session, !session.isEnding else { return }
        await session.serially { [self] in
            guard !session.isEnding else { return }
            if session.segment == nil {
                await resume(session)
            } else {
                await pause(session)
            }
        }
    }

    func discardRecording() async {
        guard let session, !session.isEnding else { return }
        beginEnding(session, as: .discarded)
        await session.serially { [self] in
            _ = await endSegment(of: session)
            var failure: (any Error)?
            for file in Set(session.parts + [session.url]) where fileExists(file) {
                do {
                    try FileManager.default.removeItem(at: file)
                } catch {
                    failure = failure ?? error
                }
            }
            try? FileManager.default.removeItem(at: session.partsFolder)
            if self.session === session { self.session = nil }
            if let failure { present(failure, failure: "Lunetta couldn't discard the recording") }
        }
    }

    /// The segment watcher ends the whole recording when its stream stops without being asked, like when the recorded window closes.
    private func attach(_ recording: any ActiveRecording, writingTo url: URL, in session: RecordingSession) {
        let finished = Task<(any Error)?, Never> {
            do {
                try await recording.finished()
                return nil
            } catch {
                return error
            }
        }
        session.segment = RecordingSession.Segment(recording: recording, url: url, end: finished)
        Task {
            _ = await finished.value
            guard session.segment?.url == url, !session.isEnding else { return }
            await self.end(session)
        }
    }

    /// The clock stops on the click; the file catches up while the stream winds down.
    private func pause(_ session: RecordingSession) async {
        session.status.clock.pause(at: now())
        onRecordingEvent(.paused(session.status))
        guard let failure = await endSegment(of: session) else { return }
        beginEnding(session, as: .saved)
        await finish(session, failure: failure)
    }

    private func resume(_ session: RecordingSession) async {
        let url = session.nextPartURL()
        do {
            try FileManager.default.createDirectory(at: session.partsFolder, withIntermediateDirectories: true)
            let active = try await recorder.startRecording(session.target, to: url, options: session.options)
            session.status.clock.start(at: now())
            attach(active, writingTo: url, in: session)
            guard !session.isEnding else { return }
            onRecordingEvent(.resumed(session.status))
        } catch {
            beginEnding(session, as: .saved)
            await finish(session, failure: error)
        }
    }

    private func end(_ session: RecordingSession) async {
        beginEnding(session, as: .saved)
        await session.serially { [self] in await finish(session, failure: nil) }
    }

    /// The controls go away on the click; joining the parts and handing over the file follow.
    private func beginEnding(_ session: RecordingSession, as end: RecordingEnd) {
        session.isEnding = true
        hide(session.overlays)
        onRecordingEvent(.ended(end))
    }

    private func finish(_ session: RecordingSession, failure: (any Error)?) async {
        let segmentFailure = await endSegment(of: session)
        var problem = failure ?? segmentFailure
        do {
            try await assemble(session)
        } catch {
            problem = problem ?? error
        }
        if self.session === session { self.session = nil }
        let saved = fileExists(session.url)
        if saved { onSaved(session.url, nil, compressIfOn(session.url)) }
        if let lost = session.lostInput { problem = CoordinatorError.inputDisconnected(lost, savedTo: saved ? session.url : nil) }
        guard let problem else { return }
        let stoppedEarly = if case .recordingStoppedEarly = problem as? CaptureError { true } else { session.lostInput != nil }
        present(problem, failure: stoppedEarly ? "Lunetta's recording stopped early" : "Lunetta couldn't finish the recording")
    }

    private func endSegment(of session: RecordingSession) async -> (any Error)? {
        guard let segment = session.segment else { return nil }
        session.segment = nil
        session.status.clock.pause(at: now())
        await segment.recording.stop()
        let failure = await segment.end.value
        if fileExists(segment.url) { session.parts.append(segment.url) }
        return failure
    }

    /// The first part is recorded straight into the final file. Later parts get joined into it, after the first part
    /// moves aside so the joined file can take its name; when the join fails, the first part goes back.
    private func assemble(_ session: RecordingSession) async throws {
        defer { try? FileManager.default.removeItem(at: session.partsFolder) }
        var parts = session.parts
        guard parts != [session.url], !parts.isEmpty else { return }
        if parts.count == 1 {
            return try FileManager.default.moveItem(at: parts[0], to: session.url)
        }
        if parts[0] == session.url {
            let first = session.partsFolder.appending(path: "part-0.mp4")
            try FileManager.default.moveItem(at: session.url, to: first)
            parts[0] = first
        }
        do {
            try await recorder.join(parts, into: session.url)
        } catch {
            if !fileExists(session.url) { try? FileManager.default.moveItem(at: parts[0], to: session.url) }
            throw error
        }
    }

    private func selectRecordingTarget(_ mode: RecordingMode) async throws -> (target: RecordingTarget, region: CGRect, display: DisplayInfo)? {
        switch mode {
        case .area:
            guard case .area(let selection) = try await selector.selectArea(frozen: []) else { return nil }
            guard let display = DisplayGeometry.display(forSelection: selection, in: await capturer.displays()) else {
                throw CaptureError.emptySelection
            }
            let region = selection.intersection(display.frame)
            return (.area(region, on: display), region, display)
        case .window:
            let windows = windowList()
            guard case .window(let id) = try await selector.selectWindow(windows) else {
                windows.cancel()
                return nil
            }
            guard let window = try await windows.value.first(where: { $0.id == id }) else { throw CaptureError.windowNotFound(id) }
            let displays = await capturer.displays()
            let mainDisplayHeight = displays.first { $0.frame.origin == .zero }?.frame.height ?? 0
            let region = DisplayGeometry.appKitRect(fromTopLeftGlobal: window.frame, mainDisplayHeight: mainDisplayHeight)
            guard let display = DisplayGeometry.display(forSelection: region, in: displays) else { throw CaptureError.windowNotFound(id) }
            return (.window(id), region, display)
        }
    }

    /// Detached: a main-actor task only starts the request once the overlay is up, and the request then runs beside it.
    /// The list reached the picker at 96.5 ms median that way, 59.1 ms detached (ui-macos run 45517264886, #41).
    private func windowList() -> Task<[CapturableWindow], any Error> {
        let capturer = capturer
        return Task.detached(priority: .userInitiated) { try await capturer.shareableWindows() }
    }

    private func nextFileURL(ext: String) -> URL {
        CaptureNaming.uniqueFileURL(
            in: settings.saveFolder,
            baseName: CaptureNaming.baseName(for: now(), timeZone: .current),
            ext: ext,
            exists: fileExists
        )
    }

    private func save(_ image: CGImage) async throws -> SavedScreenshot {
        let url = nextFileURL(ext: "png")
        let maxScale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        let maxThumbnailPixels = LunettaSettings.thumbnailWidthRange.upperBound * maxScale
        let writePNG = writePNG
        let (pngData, thumbnail) = try await Task.detached(priority: .userInitiated) {
            let data = try await writePNG(image, url)
            let thumb = ThumbnailDownsampler.downsample(image, maxPixelSize: maxThumbnailPixels)
            return (data, thumb)
        }.value
        let compression = compressIfOn(url)
        onSaved(url, thumbnail, compression)
        return SavedScreenshot(url: url, png: pngData, compression: compression)
    }

    private func compressIfOn(_ url: URL) -> PendingCompression? {
        guard settings.compressAfterCapture else { return nil }
        let compress = compress
        return Task.detached(priority: .userInitiated) { try await compress(url) }
    }

    /// Upload after capture copies the link once the bucket answers; copying the image first would only be overwritten.
    /// Each copy also waits for the one before it, so the newest capture is the one left on the clipboard.
    private func copyIfOn(_ saved: SavedScreenshot) async {
        guard settings.copyToClipboardAfterCapture, !settings.uploadAfterCapture else { return }
        let previous = clipboardCopy
        let copying = Task {
            await previous?.value
            do {
                let data = try await bytesAfterCompression(saved)
                try copyToClipboard(saved.url, data)
            } catch {
                present(CoordinatorError.clipboardFailed(savedTo: saved.url, reason: error.localizedDescription))
            }
        }
        clipboardCopy = copying
        await copying.value
    }

    /// The saved bytes unless compression replaced the file. A compression that failed left the file as saved, and its
    /// card reports the failure.
    private func bytesAfterCompression(_ saved: SavedScreenshot) async throws -> Data {
        guard let compression = saved.compression else { return saved.png }
        let outcome = await compression.result
        guard case .success(.some) = outcome else { return saved.png }
        return try Data(contentsOf: saved.url)
    }

    nonisolated static func writePNG(_ image: CGImage, to url: URL) throws -> Data {
        let data = try PNGWriter.encode(image, path: url.path)
        try PNGWriter.write(data, to: url)
        return data
    }

    private func selectAndCapture(_ mode: CaptureMode) async throws -> CGImage? {
        switch mode {
        case .area:
            guard settings.freezeScreenWhileSelecting else {
                guard case .area(let rect) = try await selector.selectArea(frozen: []) else { return nil }
                let displays = await capturer.displays()
                return try await capturer.captureArea(rect, displays: displays)
            }
            let frozen = try await freezeDisplays()
            guard case .area(let rect) = try await selector.selectArea(frozen: frozen) else { return nil }
            return try Self.crop(rect, from: frozen)
        case .window:
            let windows = windowList()
            guard case .window(let id) = try await selector.selectWindow(windows) else {
                windows.cancel()
                return nil
            }
            return try await capturer.captureWindow(id: id, wallpaperPadding: settings.wallpaperPaddingForWindowCaptures)
        case .fullScreen:
            let displays = await capturer.displays()
            guard let display = DisplayGeometry.display(nearest: pointerLocation(), in: displays) else {
                throw CoordinatorError.noDisplays
            }
            return try await capturer.captureDisplay(display)
        case .scrolling:
            return try await captureScrolling()
        }
    }

    private func captureScrolling() async throws -> CGImage? {
        guard case .area(let area) = try await selector.selectArea(frozen: []) else { return nil }
        let displays = await capturer.displays()
        guard let display = DisplayGeometry.display(forSelection: area, in: displays) else { throw CoordinatorError.noDisplays }
        // The stream hides Lunetta's windows by the IDs it reads when it starts, so the stage has to be up before it.
        scrollStager.prepare(area, on: display)
        let frames: ScrollingFrames
        do {
            frames = try await capturer.scrollingFrames(of: area, displays: displays)
        } catch {
            scrollStager.dismiss()
            throw error
        }
        let (firstFrame, firstFrameArrived) = AsyncStream<Void>.makeStream()
        scrollStageIsDeciding = true
        let stitching = stitch(frames.frames, previewRows: scrollStager.previewPixelHeight, firstFrameArrived: firstFrameArrived)
        let (outcomes, post) = AsyncStream<Result<ScrollStageDecision, any Error>>.makeStream()
        let deciding = Task { post.yield(.success(await scrollStager.decision())) }
        Task {
            if case .failure(let error) = await stitching.result { post.yield(.failure(error)) }
        }
        var next = outcomes.makeAsyncIterator()
        let outcome = await next.next()
        post.finish()
        scrollStageIsDeciding = false
        do {
            switch outcome {
            case .success(.done):
                // Done can come before the stream's first frame, which would leave nothing to save.
                for await _ in firstFrame {}
                await frames.stop()
                return try await stitching.value
            case .success(.cancelled), nil:
                stitching.cancel()
                _ = await stitching.result
                await frames.stop()
                return nil
            case .failure(let error):
                deciding.cancel()
                await frames.stop()
                throw error
            }
        } catch {
            scrollStager.dismiss()
            throw error
        }
    }

    private func stitch(
        _ frames: AsyncThrowingStream<Frame, any Error>,
        previewRows: Int,
        firstFrameArrived: AsyncStream<Void>.Continuation
    ) -> Task<CGImage?, any Error> {
        Task.detached { [self] in
            defer { firstFrameArrived.finish() }
            var stitcher: Stitcher?
            for try await frame in frames {
                guard !Task.isCancelled else { return nil }
                guard let current = stitcher else {
                    stitcher = Stitcher(first: frame, tuning: .measured)
                    firstFrameArrived.finish()
                    continue
                }
                let update = current.append(frame)
                let preview = current.tail(maxRows: previewRows)
                await showOnStage(update, preview: preview)
            }
            guard !Task.isCancelled else { return nil }
            return stitcher?.image()
        }
    }

    private func showOnStage(_ update: StitchUpdate, preview: CGImage?) {
        guard scrollStageIsDeciding else { return }
        scrollStager.show(update, preview: preview)
    }

    private func freezeDisplays() async throws -> [FrozenDisplay] {
        let displays = await capturer.displays()
        guard !displays.isEmpty else { throw CoordinatorError.noDisplays }
        let capturer = capturer
        return try await withThrowingTaskGroup(of: FrozenDisplay.self) { group in
            for display in displays {
                group.addTask { FrozenDisplay(display: display, image: try await capturer.captureDisplay(display)) }
            }
            var frozen: [FrozenDisplay] = []
            for try await grab in group {
                frozen.append(grab)
            }
            return frozen
        }
    }

    static func crop(_ selection: CGRect, from frozen: [FrozenDisplay]) throws -> CGImage {
        guard let display = DisplayGeometry.display(forSelection: selection, in: frozen.map(\.display)),
              let grab = frozen.first(where: { $0.display == display }),
              let sourceRect = DisplayGeometry.sourceRect(for: selection, on: display),
              let image = grab.image.cropping(to: DisplayGeometry.pixelRect(of: sourceRect, on: display))
        else { throw CaptureError.emptySelection }
        return image
    }

    private func present(_ error: any Error, failure: String = "Lunetta couldn't take the screenshot") {
        let needsPermission = (error as? CaptureError) == .permissionDenied
        let fix = (error as? RecordingProblem)?.fix
        let savedButNotCopied = if case .clipboardFailed = error as? CoordinatorError { true } else { false }
        let alert = CaptureAlert(
            title: savedButNotCopied ? "Lunetta saved the screenshot but couldn't copy it" : failure,
            message: error.localizedDescription,
            buttons: needsPermission ? [.openSystemSettings, .ok] : fix.map { [CaptureAlert.Button($0), .ok] } ?? [.ok]
        )
        switch alerts.present(alert) {
        case .ok:
            break
        case .openSystemSettings:
            // CGPreflightScreenCaptureAccess never registers Lunetta with TCC; without this request
            // Lunetta is missing from the Screen Recording list and the user has to add it by hand.
            _ = CapturePermission.request()
            CapturePermission.openSettings()
        case .allowMicrophone:
            Task { await self.fix(.allowMicrophone) }
        case .openMicrophoneSettings:
            microphone.openSettings()
        case .allowCamera:
            Task { await self.fix(.allowCamera) }
        case .openCameraSettings:
            camera.openSettings()
        case .openInputMonitoringSettings:
            keystrokes.openSettings()
        }
    }
}
