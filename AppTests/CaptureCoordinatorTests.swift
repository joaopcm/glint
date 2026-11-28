import CoreGraphics
import Foundation
import ImageIO
import LunettaCapture
import LunettaCore
import Testing
@testable import Lunetta

private let mainDisplay = DisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 2)
private let leftDisplay = DisplayInfo(id: 2, frame: CGRect(x: -1920, y: -200, width: 1920, height: 1080), scale: 1)

private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private actor FakeCapturer: Capturing {
    let displayList: [DisplayInfo]
    let failure: CaptureError?
    let permissionGranted: Bool
    let windowListGate: Gate?
    let windows: [CapturableWindow]
    let scrollFrames: [CGImage]
    let scrollError: CaptureError?
    let scrollStartError: CaptureError?
    let onScrollingFrames: (@Sendable () async -> Void)?
    private(set) var scrollStopCount = 0
    private(set) var capturedDisplayIDs: [UInt32] = []
    private(set) var capturedWindowIDs: [UInt32] = []
    private(set) var windowWallpaperPaddings: [Double?] = []
    private(set) var windowListServed = false
    private(set) var areaCaptureCount = 0

    init(
        displays: [DisplayInfo] = [mainDisplay],
        failure: CaptureError? = nil,
        permissionGranted: Bool = true,
        windowListGate: Gate? = nil,
        windows: [CapturableWindow] = [],
        scrollFrames: [CGImage] = [],
        scrollError: CaptureError? = nil,
        scrollStartError: CaptureError? = nil,
        onScrollingFrames: (@Sendable () async -> Void)? = nil
    ) {
        displayList = displays
        self.windows = windows
        self.scrollFrames = scrollFrames
        self.scrollError = scrollError
        self.scrollStartError = scrollStartError
        self.onScrollingFrames = onScrollingFrames
        self.failure = failure
        self.permissionGranted = permissionGranted
        self.windowListGate = windowListGate
    }

    func hasPermission() async -> Bool { permissionGranted }

    func displays() async -> [DisplayInfo] { displayList }

    func captureArea(_ selection: CGRect, displays: [DisplayInfo]) async throws -> CGImage {
        areaCaptureCount += 1
        return try image()
    }

    func captureDisplay(_ display: DisplayInfo) async throws -> CGImage {
        capturedDisplayIDs.append(display.id)
        let size = DisplayGeometry.pixelSize(of: display.frame, scale: display.scale)
        return try image(width: size.width, height: size.height)
    }

    func captureWindow(id: UInt32, wallpaperPadding: Double?) async throws -> CGImage {
        capturedWindowIDs.append(id)
        windowWallpaperPaddings.append(wallpaperPadding)
        return try image()
    }

    func shareableWindows() async throws -> [CapturableWindow] {
        await windowListGate?.wait()
        windowListServed = true
        if let failure { throw failure }
        return windows
    }

    func scrollingFrames(of selection: CGRect, displays: [DisplayInfo]) async throws -> ScrollingFrames {
        await onScrollingFrames?()
        if let scrollStartError { throw scrollStartError }
        let (frames, continuation) = AsyncThrowingStream<Frame, any Error>.makeStream()
        for image in scrollFrames { continuation.yield(Frame(image)!) }
        if let scrollError { continuation.finish(throwing: scrollError) }
        return ScrollingFrames(frames: frames, stop: { [self] in
            await recordScrollStop()
            continuation.finish()
        })
    }

    private func recordScrollStop() { scrollStopCount += 1 }

    private func image(width: Int = 10, height: Int = 10) throws -> CGImage {
        if let failure { throw failure }
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }
}

private actor FakeRecording: ActiveRecording {
    let url: URL
    let outcome: CaptureError?
    private let stopGate = Gate()
    private(set) var stopCount = 0

    init(url: URL, outcome: CaptureError?, endsOnItsOwn: Bool) {
        self.url = url
        self.outcome = outcome
        if endsOnItsOwn { Task { [stopGate] in await stopGate.open() } }
    }

    func stop() async {
        stopCount += 1
        await stopGate.open()
    }

    func finished() async throws {
        await stopGate.wait()
        FileManager.default.createFile(atPath: url.path, contents: Data("part \(url.lastPathComponent);".utf8))
        if let outcome { throw outcome }
    }
}

private actor FakeRecorder: Recording {
    let startFailure: CaptureError?
    let failingStart: Int?
    let outcome: CaptureError?
    let endsOnItsOwn: Bool
    let joinFailure: CaptureError?
    private(set) var starts: [(target: RecordingTarget, url: URL, options: RecordingOptions)] = []
    private(set) var recordings: [FakeRecording] = []
    private(set) var joins: [(parts: [URL], url: URL)] = []

    /// `failingStart` is the 1-based start that throws `startFailure`; nil makes every start throw it.
    init(
        startFailure: CaptureError? = nil,
        failingStart: Int? = nil,
        outcome: CaptureError? = nil,
        endsOnItsOwn: Bool = false,
        joinFailure: CaptureError? = nil
    ) {
        self.startFailure = startFailure
        self.failingStart = failingStart
        self.outcome = outcome
        self.endsOnItsOwn = endsOnItsOwn
        self.joinFailure = joinFailure
    }

    func startRecording(_ target: RecordingTarget, to url: URL, options: RecordingOptions) async throws -> any ActiveRecording {
        if let startFailure, failingStart == nil || failingStart == starts.count + 1 { throw startFailure }
        starts.append((target, url, options))
        let recording = FakeRecording(url: url, outcome: outcome, endsOnItsOwn: endsOnItsOwn)
        recordings.append(recording)
        return recording
    }

    func join(_ parts: [URL], into url: URL) async throws {
        joins.append((parts, url))
        if let joinFailure { throw joinFailure }
        let joined = try parts.reduce(into: Data()) { $0.append(try Data(contentsOf: $1)) }
        try joined.write(to: url)
    }
}

@MainActor
private final class FakeCountdown {
    var proceeds = true
    var during: (@MainActor () async -> Void)?
    private(set) var shown: [RecordingStatus] = []

    func run(_ status: RecordingStatus) async -> Bool {
        shown.append(status)
        await during?()
        return proceeds && !Task.isCancelled
    }
}

@MainActor
private final class FakeMicrophone: MicrophoneAccess {
    var status: DeviceAccess
    var inputs: [AudioInput]
    let grants: Bool
    private(set) var requestCount = 0
    private(set) var settingsOpened = 0

    init(_ status: DeviceAccess = .authorized, grants: Bool = true, inputs: [AudioInput] = []) {
        self.status = status
        self.grants = grants
        self.inputs = inputs
    }

    func requestAccess() async -> Bool {
        requestCount += 1
        status = grants ? .authorized : .denied
        return grants
    }

    func openSettings() {
        settingsOpened += 1
    }
}

@MainActor
private final class FakeKeystrokes: KeystrokeShowing {
    var isAllowed: Bool
    private(set) var shownOver: [CGRect] = []
    private(set) var hideCount = 0
    private(set) var settingsOpened = 0

    init(allowed: Bool = true) { isAllowed = allowed }

    func show(over region: CGRect) throws {
        guard isAllowed else { throw RecordingProblem.inputMonitoringDenied }
        shownOver.append(region)
    }

    func hide() { hideCount += 1 }

    func openSettings() { settingsOpened += 1 }
}

@MainActor
private final class FakeClickRings: ClickShowing {
    private(set) var shownOver: [CGRect] = []
    private(set) var hideCount = 0

    func show(over region: CGRect) {
        shownOver.append(region)
    }

    func hide() { hideCount += 1 }
}

private let faceTime = CameraInput(id: "facetime", name: "FaceTime HD Camera")
private let deskCam = CameraInput(id: "usb-cam", name: "Desk Cam")

@MainActor
private final class FakeCamera: CameraShowing {
    var access: DeviceAccess
    var cameras: [CameraInput]
    var refusal: CameraBubbleError?
    private(set) var shown: [(region: CGRect, camera: CameraInput?)] = []
    private(set) var hideCount = 0
    private(set) var requestCount = 0
    private(set) var settingsOpened = 0

    init(_ access: DeviceAccess = .authorized, cameras: [CameraInput] = [faceTime, deskCam]) {
        self.access = access
        self.cameras = cameras
    }

    func requestAccess() async -> Bool {
        requestCount += 1
        access = .authorized
        return true
    }

    func openSettings() { settingsOpened += 1 }

    func show(over region: CGRect, camera: CameraInput?) throws {
        if let refusal { throw refusal }
        shown.append((region, camera))
    }

    func hide() { hideCount += 1 }
}

@MainActor
private final class FakeStager: RecordingStaging {
    var answer: (CGRect) -> CGRect? = { $0 }
    var whileStaged: (@MainActor () -> Void)?
    private(set) var staged: [(region: CGRect, display: DisplayInfo, mode: RecordingMode)] = []

    func stage(_ region: CGRect, on display: DisplayInfo, mode: RecordingMode) async -> CGRect? {
        staged.append((region, display, mode))
        whileStaged?()
        return answer(region)
    }
}

@MainActor
private final class FakeScrollStager: ScrollStaging {
    let previewPixelHeight = 100
    var answer: ScrollStageDecision?
    var expectedShows = 0
    var onPrepare: (@MainActor () -> Void)?
    private(set) var prepared: [(area: CGRect, display: DisplayInfo)] = []
    private(set) var shown: [(update: StitchUpdate, preview: CGImage?)] = []
    private(set) var dismissCount = 0
    private var waiting: CheckedContinuation<ScrollStageDecision, Never>?

    init(_ answer: ScrollStageDecision? = .done) { self.answer = answer }

    func prepare(_ area: CGRect, on display: DisplayInfo) {
        prepared.append((area, display))
        onPrepare?()
    }

    func decision() async -> ScrollStageDecision {
        await withCheckedContinuation { waiting = $0; resolveIfReady() }
    }

    func show(_ update: StitchUpdate, preview: CGImage?) {
        shown.append((update, preview))
        resolveIfReady()
    }

    func dismiss() {
        dismissCount += 1
        waiting?.resume(returning: .cancelled)
        waiting = nil
    }

    private func resolveIfReady() {
        guard let answer, shown.count >= expectedShows, let waiting else { return }
        self.waiting = nil
        waiting.resume(returning: answer)
    }
}

@MainActor
private final class FakeSelector: Selecting {
    let result: SelectionResult
    private(set) var selectionCount = 0
    private(set) var frozenDisplayIDs: [UInt32] = []
    var whileSelecting: (@MainActor () async -> Void)?

    init(_ result: SelectionResult) { self.result = result }

    func selectArea(frozen: [FrozenDisplay]) async throws -> SelectionResult {
        selectionCount += 1
        frozenDisplayIDs = frozen.map(\.display.id).sorted()
        await whileSelecting?()
        return result
    }

    func selectWindow(_ windows: Task<[CapturableWindow], any Error>) async throws -> SelectionResult {
        selectionCount += 1
        await whileSelecting?()
        _ = try await windows.value
        return result
    }
}

@MainActor
private final class FakeAlerts: AlertPresenting {
    private(set) var presented: [CaptureAlert] = []
    var answer: CaptureAlert.Button = .ok

    func present(_ alert: CaptureAlert) -> CaptureAlert.Button {
        presented.append(alert)
        return answer
    }
}

private final class MemoryStore: KeyValueStore {
    private var values: [String: Any] = [:]

    func string(forKey key: String) -> String? { values[key] as? String }
    func set(_ value: String?, forKey key: String) { values[key] = value }
    func bool(forKey key: String) -> Bool? { values[key] as? Bool }
    func set(_ value: Bool, forKey key: String) { values[key] = value }
    func double(forKey key: String) -> Double? { values[key] as? Double }
    func set(_ value: Double, forKey key: String) { values[key] = value }
}

@MainActor
private struct Harness {
    let folder: URL
    let alerts = FakeAlerts()
    let selector: FakeSelector
    let settings: LunettaSettings
    let microphone: FakeMicrophone
    let keystrokes: FakeKeystrokes
    let clickRings = FakeClickRings()
    let camera: FakeCamera
    let stager = FakeStager()
    let scrollStager: FakeScrollStager
    let countdown = FakeCountdown()
    let coordinator: CaptureCoordinator

    init(
        capturer: FakeCapturer = FakeCapturer(),
        recorder: FakeRecorder = FakeRecorder(),
        microphone: FakeMicrophone = FakeMicrophone(),
        keystrokes: FakeKeystrokes = FakeKeystrokes(),
        camera: FakeCamera = FakeCamera(),
        scrollStager: FakeScrollStager = FakeScrollStager(),
        selection: SelectionResult,
        pointer: CGPoint = .zero,
        createFolder: Bool = true,
        clipboardOn: Bool? = nil,
        uploadOn: Bool = false,
        freezeOn: Bool = false,
        codec: VideoCodec = .h264,
        frameRate: RecordingFrameRate = .sixty,
        systemAudio: Bool = false,
        recordMicrophone: Bool = false,
        input: AudioInput? = nil,
        recordCamera: Bool = false,
        cameraInput: CameraInput? = nil,
        showsKeys: Bool = false,
        showsClicks: Bool = false,
        countsDown: Bool = false,
        soundOn: Bool = true,
        now: @escaping () -> Date = { recordingStart },
        onShutter: @escaping @MainActor () -> Void = {},
        copyToClipboard: (@MainActor (URL) throws -> Void)? = nil,
        copiedBytes: @escaping @MainActor (Data) -> Void = { _ in },
        writePNG: (@Sendable (CGImage, URL) async throws -> Data)? = nil,
        compressOn: Bool = false,
        compress: @escaping @Sendable (URL) async throws -> CompressionResult? = { _ in nil },
        onSaved: @escaping @MainActor (URL) -> Void = { _ in },
        onCompression: @escaping @MainActor (PendingCompression?) -> Void = { _ in },
        onRecordingEvent: @escaping @MainActor (RecordingEvent) -> Void = { _ in }
    ) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "LunettaTests-\(UUID().uuidString)")
        folder = createFolder ? root : root.appending(path: "missing")
        if createFolder {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let settings = LunettaSettings(store: MemoryStore(), defaultSaveFolder: folder)
        settings.copyToClipboardAfterCapture = clipboardOn ?? (copyToClipboard != nil)
        settings.uploadAfterCapture = uploadOn
        settings.compressAfterCapture = compressOn
        settings.freezeScreenWhileSelecting = freezeOn
        settings.recordingCodec = codec
        settings.recordingFrameRate = frameRate
        settings.recordSystemAudio = systemAudio
        settings.recordMicrophone = recordMicrophone
        settings.recordingInput = input
        settings.recordCamera = recordCamera
        settings.recordingCamera = cameraInput
        settings.showPressedKeys = showsKeys
        settings.showMouseClicks = showsClicks
        settings.recordingCountdown = countsDown
        settings.playSoundOnCapture = soundOn
        self.settings = settings
        self.microphone = microphone
        self.keystrokes = keystrokes
        self.camera = camera
        self.scrollStager = scrollStager
        selector = FakeSelector(selection)
        coordinator = CaptureCoordinator(
            capturer: capturer,
            recorder: recorder,
            microphone: microphone,
            keystrokes: keystrokes,
            clickRings: clickRings,
            camera: camera,
            stager: stager,
            scrollStager: scrollStager,
            selector: selector,
            alerts: alerts,
            settings: settings,
            now: now,
            fileExists: { FileManager.default.fileExists(atPath: $0.path) },
            pointerLocation: { pointer },
            copyToClipboard: { url, data in
                try copyToClipboard?(url)
                copiedBytes(data)
            },
            writePNG: writePNG ?? CaptureCoordinator.writePNG,
            compress: compress,
            playShutterSound: onShutter,
            onSaved: { url, _, compression in
                onSaved(url)
                onCompression(compression)
            },
            onRecordingEvent: onRecordingEvent,
            countDown: { [countdown] in await countdown.run($0) }
        )
    }

    func savedFiles() throws -> [String] {
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: folder.path)
    }
}

@MainActor @Test func cancelWritesNothing() async throws {
    let harness = try Harness(selection: .cancelled)
    await harness.coordinator.run(.area)
    #expect(try harness.savedFiles().isEmpty)
    #expect(harness.alerts.presented.isEmpty)
}

@MainActor @Test func areaWritesOnePNG() async throws {
    let harness = try Harness(selection: .area(CGRect(x: 10, y: 10, width: 5, height: 5)))
    await harness.coordinator.run(.area)
    let files = try harness.savedFiles()
    #expect(files.count == 1)
    let name = try #require(files.first)
    #expect(name.hasPrefix("Lunetta ") && name.contains(" at ") && name.hasSuffix(".png"))
    #expect(harness.alerts.presented.isEmpty)
}

@MainActor @Test func savedCaptureIsHandedToThumbnail() async throws {
    var handed: [URL] = []
    let harness = try Harness(selection: .area(CGRect(x: 10, y: 10, width: 5, height: 5)), onSaved: { handed.append($0) })
    await harness.coordinator.run(.area)
    #expect(handed.map(\.lastPathComponent) == (try harness.savedFiles()))
}

@MainActor @Test(arguments: [(CaptureMode.area, SelectionResult.area(CGRect(x: 10, y: 10, width: 5, height: 5))), (.window, .window(42)), (.fullScreen, .cancelled)])
func eachScreenshotPlaysTheShutterOnce(mode: CaptureMode, selection: SelectionResult) async throws {
    var shutters = 0
    let harness = try Harness(selection: selection, onShutter: { shutters += 1 })
    await harness.coordinator.run(mode)
    #expect(shutters == 1)
    #expect(try harness.savedFiles().count == 1)
}

@MainActor @Test func cancelledOrFailedCapturePlaysNoShutter() async throws {
    var shutters = 0
    let cancelled = try Harness(selection: .cancelled, onShutter: { shutters += 1 })
    await cancelled.coordinator.run(.area)
    let denied = try Harness(capturer: FakeCapturer(permissionGranted: false), selection: .window(7), onShutter: { shutters += 1 })
    await denied.coordinator.run(.window)
    #expect(shutters == 0)
}

@MainActor @Test func soundOffPlaysNoShutter() async throws {
    var shutters = 0
    let harness = try Harness(selection: .area(CGRect(x: 10, y: 10, width: 5, height: 5)), soundOn: false, onShutter: { shutters += 1 })
    await harness.coordinator.run(.area)
    #expect(shutters == 0)
    #expect(try harness.savedFiles().count == 1)
}

@MainActor @Test func captureTextPlaysTheShutterOnce() async throws {
    var shutters = 0
    let harness = try Harness(selection: .area(CGRect(x: 10, y: 10, width: 5, height: 5)), onShutter: { shutters += 1 })
    _ = await harness.coordinator.captureImage(.area)
    #expect(shutters == 1)
}

@MainActor @Test func captureTextWithSoundOffPlaysNoShutter() async throws {
    var shutters = 0
    let harness = try Harness(selection: .area(CGRect(x: 10, y: 10, width: 5, height: 5)), soundOn: false, onShutter: { shutters += 1 })
    _ = await harness.coordinator.captureImage(.area)
    #expect(shutters == 0)
}

@MainActor @Test func windowCapturesPickedWindow() async throws {
    let capturer = FakeCapturer()
    let harness = try Harness(capturer: capturer, selection: .window(42))
    await harness.coordinator.run(.window)
    #expect(await capturer.capturedWindowIDs == [42])
    #expect(try harness.savedFiles().count == 1)
    #expect(harness.alerts.presented.isEmpty)
}

@MainActor @Test func windowCaptureLeavesTheWallpaperOutByDefault() async throws {
    let capturer = FakeCapturer()
    let harness = try Harness(capturer: capturer, selection: .window(42))
    await harness.coordinator.run(.window)
    #expect(await capturer.windowWallpaperPaddings == [nil])
}

@MainActor @Test func windowCaptureAsksForTheWallpaperWithTheChosenPadding() async throws {
    let capturer = FakeCapturer()
    let harness = try Harness(capturer: capturer, selection: .window(42))
    harness.settings.windowCaptureWallpaper = true
    harness.settings.windowWallpaperPadding = 96
    await harness.coordinator.run(.window)
    #expect(await capturer.windowWallpaperPaddings == [96])
    #expect(try harness.savedFiles().count == 1)
}

@MainActor @Test func wallpaperFailureTellsTheUserHowToTurnItOff() async throws {
    let harness = try Harness(capturer: FakeCapturer(failure: .wallpaperUnavailable("macOS listed no desktop wallpaper window")), selection: .window(7))
    harness.settings.windowCaptureWallpaper = true
    await harness.coordinator.run(.window)
    let alert = try #require(harness.alerts.presented.first)
    #expect(alert.message.contains("Wallpaper behind window captures"))
    #expect(try harness.savedFiles().isEmpty)
}

// A regression that awaits the list before showing the picker would hang on the gate; 1 minute is the smallest limit Swift Testing takes.
@MainActor @Test(.timeLimit(.minutes(1))) func windowPickerShowsBeforeTheWindowListArrives() async throws {
    let gate = Gate()
    let capturer = FakeCapturer(windowListGate: gate)
    let harness = try Harness(capturer: capturer, selection: .window(42))
    var listServedBeforePicker: Bool?
    harness.selector.whileSelecting = {
        listServedBeforePicker = await capturer.windowListServed
        await gate.open()
    }
    await harness.coordinator.run(.window)
    #expect(listServedBeforePicker == false)
    #expect(await capturer.capturedWindowIDs == [42])
}

@MainActor @Test func windowListFailureThrowsItsReasonFromThePicker() async {
    let controller = SelectionOverlayController(showsMagnifier: { false }, snapshot: { _ in throw CaptureError.emptySelection })
    let windows = Task<[CapturableWindow], any Error> { throw CaptureError.permissionDenied }
    await #expect(throws: CaptureError.permissionDenied) { try await controller.selectWindow(windows) }
}

@MainActor @Test func permissionDeniedShowsSettingsAlert() async throws {
    let harness = try Harness(capturer: FakeCapturer(failure: .permissionDenied), selection: .window(7))
    await harness.coordinator.run(.window)
    let alert = try #require(harness.alerts.presented.first)
    #expect(alert.buttons.map(\.rawValue).contains("Open System Settings"))
    #expect(alert.message == CaptureError.permissionDenied.localizedDescription)
    #expect(try harness.savedFiles().isEmpty)
}

@MainActor @Test(arguments: [CaptureMode.area, .window, .fullScreen])
func permissionDeniedAlertsBeforeAnyOverlay(mode: CaptureMode) async throws {
    let capturer = FakeCapturer(permissionGranted: false)
    let harness = try Harness(capturer: capturer, selection: .area(CGRect(x: 10, y: 10, width: 5, height: 5)))
    await harness.coordinator.run(mode)
    #expect(harness.selector.selectionCount == 0)
    #expect(await capturer.capturedDisplayIDs.isEmpty)
    let alert = try #require(harness.alerts.presented.first)
    #expect(alert.buttons.contains(.openSystemSettings))
    #expect(try harness.savedFiles().isEmpty)
}

@MainActor @Test func fullScreenUsesNearestDisplay() async throws {
    let capturer = FakeCapturer(displays: [leftDisplay, mainDisplay])
    let harness = try Harness(capturer: capturer, selection: .cancelled, pointer: CGPoint(x: 700, y: 982))
    await harness.coordinator.run(.fullScreen)
    #expect(await capturer.capturedDisplayIDs == [mainDisplay.id])
    #expect(try harness.savedFiles().count == 1)
}

@MainActor @Test func secondCaptureInTheSameSecondGetsCounterSuffix() async throws {
    let harness = try Harness(selection: .area(CGRect(x: 10, y: 10, width: 5, height: 5)))
    await harness.coordinator.run(.area)
    let first = try #require(try harness.savedFiles().first)
    let firstBytes = try Data(contentsOf: harness.folder.appending(path: first))
    await harness.coordinator.run(.area)
    let base = String(first.dropLast(".png".count))
    #expect(Set(try harness.savedFiles()) == [first, "\(base) (2).png"])
    #expect(try Data(contentsOf: harness.folder.appending(path: first)) == firstBytes)
    #expect(harness.alerts.presented.isEmpty)
}

@MainActor @Test func missingSaveFolderAlertNamesPathAndOSReason() async throws {
    let harness = try Harness(selection: .area(CGRect(x: 10, y: 10, width: 5, height: 5)), createFolder: false)
    await harness.coordinator.run(.area)
    let alert = try #require(harness.alerts.presented.first)
    #expect(alert.message.contains(harness.folder.path))
    #expect(alert.message.contains("No such file or directory"))
    #expect(!alert.buttons.contains(.openSystemSettings))
    #expect(!FileManager.default.fileExists(atPath: harness.folder.deletingLastPathComponent().path))
}

@MainActor @Test func readOnlySaveFolderAlertNamesPathAndOSReason() async throws {
    let harness = try Harness(selection: .area(CGRect(x: 10, y: 10, width: 5, height: 5)))
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: harness.folder.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: harness.folder.path) }
    await harness.coordinator.run(.area)
    let alert = try #require(harness.alerts.presented.first)
    #expect(alert.message.contains(harness.folder.path))
    #expect(alert.message.contains("Permission denied"))
    #expect(try harness.savedFiles().isEmpty)
}

@MainActor @Test func clipboardOnCopiesTheSavedFile() async throws {
    var copied: [URL] = []
    let harness = try Harness(
        selection: .area(CGRect(x: 10, y: 10, width: 5, height: 5)),
        clipboardOn: true,
        copyToClipboard: { copied.append($0) }
    )
    await harness.coordinator.run(.area)
    let saved = try #require(try harness.savedFiles().first)
    #expect(copied.map(\.lastPathComponent) == [saved])
}

@MainActor @Test func clipboardOffNeverTouchesTheClipboard() async throws {
    var copied: [URL] = []
    let harness = try Harness(
        selection: .area(CGRect(x: 10, y: 10, width: 5, height: 5)),
        clipboardOn: false,
        copyToClipboard: { copied.append($0) }
    )
    await harness.coordinator.run(.area)
    #expect(try harness.savedFiles().count == 1)
    #expect(copied.isEmpty)
}

@MainActor @Test func uploadAfterCaptureLeavesTheClipboardForTheLink() async throws {
    var copied: [URL] = []
    let harness = try Harness(
        selection: .area(CGRect(x: 10, y: 10, width: 5, height: 5)),
        clipboardOn: true,
        uploadOn: true,
        copyToClipboard: { copied.append($0) }
    )
    await harness.coordinator.run(.area)
    #expect(try harness.savedFiles().count == 1)
    #expect(copied.isEmpty)
}

private actor CompressionLog {
    private(set) var files: [URL] = []

    func add(_ file: URL) {
        files.append(file)
    }
}

private struct CompressionBroke: LocalizedError {
    var errorDescription: String? { "the encoder ran out of memory" }
}

@MainActor @Test func compressOffNeverCompresses() async throws {
    let log = CompressionLog()
    var handed: [PendingCompression?] = []
    let harness = try Harness(
        selection: .area(CGRect(x: 10, y: 10, width: 5, height: 5)),
        compress: { file in
            await log.add(file)
            return nil
        },
        onCompression: { handed.append($0) }
    )
    await harness.coordinator.run(.area)
    #expect(handed.count == 1 && handed[0] == nil)
    #expect(await log.files.isEmpty)
}

@MainActor @Test func compressOnHandsTheCardTheSavedFilesCompression() async throws {
    let log = CompressionLog()
    let result = CompressionResult(originalBytes: 1000, compressedBytes: 380)
    var handed: [PendingCompression?] = []
    let harness = try Harness(
        selection: .area(CGRect(x: 10, y: 10, width: 5, height: 5)),
        compressOn: true,
        compress: { file in
            await log.add(file)
            return result
        },
        onCompression: { handed.append($0) }
    )
    await harness.coordinator.run(.area)
    let compression = try #require(handed.first ?? nil)
    let outcome = try await compression.value
    #expect(outcome == result)
    let saved = try #require(try harness.savedFiles().first)
    #expect(await log.files.map(\.lastPathComponent) == [saved])
}

@MainActor @Test func clipboardGetsTheCompressedFile() async throws {
    var copied: [Data] = []
    let harness = try Harness(
        selection: .area(CGRect(x: 10, y: 10, width: 5, height: 5)),
        clipboardOn: true,
        copiedBytes: { copied.append($0) },
        compressOn: true,
        compress: { file in
            try Data("compressed".utf8).write(to: file)
            return CompressionResult(originalBytes: 1000, compressedBytes: 10)
        }
    )
    await harness.coordinator.run(.area)
    #expect(copied == [Data("compressed".utf8)])
}

@MainActor @Test func clipboardGetsTheCaptureAsSavedWhenCompressionFailsOrGivesUp() async throws {
    let outcomes: [@Sendable (URL) async throws -> CompressionResult?] = [{ _ in throw CompressionBroke() }, { _ in nil }]
    for compress in outcomes {
        var copied: [Data] = []
        let harness = try Harness(
            selection: .area(CGRect(x: 10, y: 10, width: 5, height: 5)),
            clipboardOn: true,
            copiedBytes: { copied.append($0) },
            compressOn: true,
            compress: compress
        )
        await harness.coordinator.run(.area)
        let saved = harness.folder.appending(path: try #require(try harness.savedFiles().first))
        #expect(copied == [try Data(contentsOf: saved)])
        #expect(harness.alerts.presented.isEmpty) // the card reports a failed compression, not the clipboard
    }
}

@MainActor @Test(.timeLimit(.minutes(1))) func aCompressingCaptureNeverHoldsUpTheNextCard() async throws {
    let compressing = Gate()
    let release = Gate()
    var handed: [URL] = []
    var copied: [Data] = []
    let harness = try Harness(
        selection: .area(CGRect(x: 10, y: 10, width: 5, height: 5)),
        clipboardOn: true,
        copiedBytes: { copied.append($0) },
        compressOn: true,
        compress: { _ in
            await compressing.open()
            await release.wait()
            return nil
        },
        onSaved: { handed.append($0) }
    )
    let first = Task { await harness.coordinator.run(.area) }
    await compressing.wait()
    let second = Task { await harness.coordinator.run(.area) }
    while handed.count < 2 { await Task.yield() }
    #expect(copied.isEmpty) // both copies wait for compression
    await release.open()
    await first.value
    await second.value
    #expect(copied.count == 2)
}

private struct PasteboardLocked: LocalizedError {
    var errorDescription: String? { "the pasteboard is locked" }
}

@MainActor @Test func clipboardFailureNamesSavedPath() async throws {
    let harness = try Harness(
        selection: .area(CGRect(x: 10, y: 10, width: 5, height: 5)),
        copyToClipboard: { _ in throw PasteboardLocked() }
    )
    await harness.coordinator.run(.area)
    let files = try harness.savedFiles()
    #expect(files.count == 1)
    let savedPath = harness.folder.appending(path: try #require(files.first)).path
    let alert = try #require(harness.alerts.presented.first)
    #expect(alert.title != "Lunetta couldn't take the screenshot")
    #expect(alert.message.contains(savedPath))
    #expect(alert.message.contains("the pasteboard is locked"))
    #expect(alert.buttons == [.ok])
}

@MainActor @Test func captureImageWritesNothingAndLeavesClipboardAlone() async throws {
    var copied: [URL] = []
    var handed: [URL] = []
    let harness = try Harness(
        selection: .area(CGRect(x: 10, y: 10, width: 5, height: 5)),
        clipboardOn: true,
        copyToClipboard: { copied.append($0) },
        onSaved: { handed.append($0) }
    )
    let image = await harness.coordinator.captureImage(.area)
    #expect(image?.width == 10)
    #expect(try harness.savedFiles().isEmpty)
    #expect(copied.isEmpty)
    #expect(handed.isEmpty)
    #expect(harness.alerts.presented.isEmpty)
}

@MainActor @Test func captureImageChecksPermissionBeforeAnyOverlay() async throws {
    let harness = try Harness(capturer: FakeCapturer(permissionGranted: false), selection: .area(CGRect(x: 10, y: 10, width: 5, height: 5)))
    let image = await harness.coordinator.captureImage(.area)
    #expect(image == nil)
    #expect(harness.selector.selectionCount == 0)
    let alert = try #require(harness.alerts.presented.first)
    #expect(alert.buttons.contains(.openSystemSettings))
}

@MainActor @Test func captureWhileSelectingStartsNothing() async throws {
    let harness = try Harness(selection: .area(CGRect(x: 10, y: 10, width: 5, height: 5)))
    var reentrantImage: CGImage?
    harness.selector.whileSelecting = {
        await harness.coordinator.run(.area)
        reentrantImage = await harness.coordinator.captureImage(.area)
    }
    await harness.coordinator.run(.area)
    #expect(harness.selector.selectionCount == 1)
    #expect(reentrantImage == nil)
    #expect(try harness.savedFiles().count == 1)
}

// #99: a hotkey pressed once the PNG is on disk, while the card and clipboard are still being handled, used to be dropped.
@MainActor @Test(.timeLimit(.minutes(1))) func captureRequestedWhileTheLastOneIsDeliveringStillRuns() async throws {
    let written = Gate()
    let release = Gate()
    let harness = try Harness(selection: .area(CGRect(x: 10, y: 10, width: 5, height: 5)), writePNG: { image, url in
        let data = try CaptureCoordinator.writePNG(image, to: url)
        await written.open()
        await release.wait()
        return data
    })
    harness.selector.whileSelecting = { await release.open() }
    let first = Task { await harness.coordinator.run(.fullScreen) }
    await written.wait()
    await harness.coordinator.run(.area)
    await release.open()
    await first.value
    #expect(harness.selector.selectionCount == 1)
    #expect(try harness.savedFiles().count == 2)
    #expect(harness.alerts.presented.isEmpty)
}

@MainActor @Test func freezeOnGrabsEveryDisplayBeforeTheOverlayAndCropsFromIt() async throws {
    let capturer = FakeCapturer(displays: [mainDisplay, leftDisplay])
    let harness = try Harness(capturer: capturer, selection: .area(CGRect(x: 100, y: 782, width: 200, height: 100)), freezeOn: true)
    let image = try #require(await harness.coordinator.captureImage(.area))
    #expect(harness.selector.frozenDisplayIDs == [mainDisplay.id, leftDisplay.id])
    #expect(await capturer.capturedDisplayIDs.sorted() == [mainDisplay.id, leftDisplay.id])
    #expect(await capturer.areaCaptureCount == 0)
    #expect(image.width == 400 && image.height == 200)
}

@MainActor @Test func freezeOffNeverGrabsDisplays() async throws {
    let capturer = FakeCapturer(displays: [mainDisplay, leftDisplay])
    let harness = try Harness(capturer: capturer, selection: .area(CGRect(x: 10, y: 10, width: 5, height: 5)))
    await harness.coordinator.run(.area)
    #expect(harness.selector.frozenDisplayIDs.isEmpty)
    #expect(await capturer.capturedDisplayIDs.isEmpty)
    #expect(await capturer.areaCaptureCount == 1)
}

@MainActor @Test func freezeGrabFailureAlertsBeforeAnyOverlay() async throws {
    let harness = try Harness(capturer: FakeCapturer(failure: .displayNotFound(1)), selection: .area(CGRect(x: 10, y: 10, width: 5, height: 5)), freezeOn: true)
    await harness.coordinator.run(.area)
    #expect(harness.selector.selectionCount == 0)
    let alert = try #require(harness.alerts.presented.first)
    #expect(alert.message == CaptureError.displayNotFound(1).localizedDescription)
    #expect(try harness.savedFiles().isEmpty)
}

private let recordedArea = CGRect(x: 100, y: 200, width: 300, height: 150)
private let recordingStart = Date(timeIntervalSince1970: 1_795_000_000)

private func startedClock() -> RecordingClock {
    var clock = RecordingClock()
    clock.start(at: recordingStart)
    return clock
}

private func pausedClock() -> RecordingClock {
    var clock = startedClock()
    clock.pause(at: recordingStart)
    return clock
}

private func name(_ event: RecordingEvent) -> String {
    switch event {
    case .started: "started"
    case .paused: "paused"
    case .resumed: "resumed"
    case .ended(let end): "ended(\(end))"
    }
}

/// Watchers run as their own tasks; give them turns until `condition` holds.
@MainActor private func eventually(_ condition: @MainActor () async -> Bool) async -> Bool {
    for _ in 0..<200 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}

@MainActor @Test func recordingAnAreaStartsOnItsDisplayDimsAroundItAndStopHandsOverTheMP4() async throws {
    let recorder = FakeRecorder()
    var events: [RecordingEvent] = []
    var handed: [URL] = []
    let harness = try Harness(
        recorder: recorder,
        selection: .area(recordedArea),
        onSaved: { handed.append($0) },
        onRecordingEvent: { events.append($0) }
    )
    await harness.coordinator.toggleRecording(.area)
    let start = try #require(await recorder.starts.first)
    #expect(start.target == .area(recordedArea, on: mainDisplay))
    #expect(start.options == RecordingOptions(codec: .h264, systemAudio: false, microphone: false))
    #expect(start.url.deletingLastPathComponent().standardizedFileURL == harness.folder.standardizedFileURL)
    #expect(start.url.lastPathComponent.hasPrefix("Lunetta ") && start.url.pathExtension == "mp4")
    #expect(events == [.started(RecordingStatus(region: recordedArea, dimsOutside: true, clock: startedClock()))])
    #expect(handed.isEmpty)

    await harness.coordinator.stopRecording()
    #expect(events.map(name) == ["started", "ended(saved)"])
    #expect(handed == [start.url])
    #expect(await recorder.joins.isEmpty)
    #expect(harness.alerts.presented.isEmpty)
}

@MainActor @Test func theRecordHotkeyStopsARunningRecordingInsteadOfStartingAnother() async throws {
    let recorder = FakeRecorder()
    var handed: [URL] = []
    let harness = try Harness(recorder: recorder, selection: .area(recordedArea), onSaved: { handed.append($0) })
    await harness.coordinator.toggleRecording(.area)
    await harness.coordinator.toggleRecording(.window)
    #expect(await recorder.starts.count == 1)
    #expect(harness.selector.selectionCount == 1)
    let recording = try #require(await recorder.recordings.first)
    #expect(await recording.stopCount == 1)
    #expect(handed.count == 1)
}

@MainActor @Test func aSavedRecordingIsHandedOverWithItsCompression() async throws {
    let recorder = FakeRecorder()
    let log = CompressionLog()
    var handed: [PendingCompression?] = []
    let harness = try Harness(
        recorder: recorder,
        selection: .area(recordedArea),
        compressOn: true,
        compress: { file in
            await log.add(file)
            return nil
        },
        onCompression: { handed.append($0) }
    )
    await harness.coordinator.toggleRecording(.area)
    await harness.coordinator.stopRecording()
    let compression = try #require(handed.first ?? nil)
    let outcome = try await compression.value
    #expect(outcome == nil)
    let start = try #require(await recorder.starts.first)
    #expect(await log.files == [start.url])
}

@MainActor @Test func recordingUsesTheCodecFromSettings() async throws {
    let recorder = FakeRecorder()
    let harness = try Harness(recorder: recorder, selection: .area(recordedArea), codec: .hevc)
    await harness.coordinator.toggleRecording(.area)
    #expect(await recorder.starts.first?.options.codec == .hevc)
    await harness.coordinator.stopRecording()
}

@MainActor @Test func recordingUsesTheFrameRateFromSettings() async throws {
    let recorder = FakeRecorder()
    let harness = try Harness(recorder: recorder, selection: .area(recordedArea), frameRate: .thirty)
    await harness.coordinator.toggleRecording(.area)
    #expect(await recorder.starts.first?.options.frameRate == .thirty)
    await harness.coordinator.stopRecording()
}

@MainActor @Test func recordingAWindowFramesItInAppKitCoordinatesWithoutDimming() async throws {
    let window = CapturableWindow(id: 42, frame: CGRect(x: 50, y: 100, width: 400, height: 300))
    let recorder = FakeRecorder()
    var events: [RecordingEvent] = []
    let harness = try Harness(
        capturer: FakeCapturer(windows: [window]),
        recorder: recorder,
        selection: .window(42),
        onRecordingEvent: { events.append($0) }
    )
    await harness.coordinator.toggleRecording(.window)
    #expect(await recorder.starts.first?.target == .window(42))
    let frame = CGRect(x: 50, y: 982 - 400, width: 400, height: 300)
    #expect(events == [.started(RecordingStatus(region: frame, dimsOutside: false, clock: startedClock()))])
    await harness.coordinator.stopRecording()
}

@MainActor @Test func cancellingTheRecordingSelectionStartsNothing() async throws {
    let recorder = FakeRecorder()
    var events: [RecordingEvent] = []
    let harness = try Harness(recorder: recorder, selection: .cancelled, countsDown: true, onRecordingEvent: { events.append($0) })
    await harness.coordinator.toggleRecording(.area)
    #expect(await recorder.starts.isEmpty)
    #expect(events.isEmpty)
    #expect(harness.countdown.shown.isEmpty)
    #expect(harness.alerts.presented.isEmpty)
}

@MainActor @Test func recordingWithoutPermissionAlertsBeforeAnyOverlay() async throws {
    let recorder = FakeRecorder()
    var events: [RecordingEvent] = []
    let harness = try Harness(
        capturer: FakeCapturer(permissionGranted: false),
        recorder: recorder,
        selection: .area(recordedArea),
        onRecordingEvent: { events.append($0) }
    )
    await harness.coordinator.toggleRecording(.area)
    #expect(harness.selector.selectionCount == 0)
    #expect(await recorder.starts.isEmpty)
    #expect(events.isEmpty)
    let alert = try #require(harness.alerts.presented.first)
    #expect(alert.buttons.contains(.openSystemSettings))
}

@MainActor @Test func aRecordingThatFailsToStartSaysWhyAndTakesDownTheCountdownDim() async throws {
    let failure = CaptureError.recordingFailed(path: "/tmp/x.mp4", reason: "Start stream failed")
    var events: [RecordingEvent] = []
    let harness = try Harness(
        recorder: FakeRecorder(startFailure: failure),
        selection: .area(recordedArea),
        countsDown: true,
        onRecordingEvent: { events.append($0) }
    )
    await harness.coordinator.toggleRecording(.area)
    let alert = try #require(harness.alerts.presented.first)
    #expect(alert.title == "Lunetta couldn't start the recording")
    #expect(alert.message == failure.localizedDescription)
    #expect(events.map(name) == ["started", "ended(failed)"], "the HUD goes up before the stream starts, so the recording can leave it out")
}

@MainActor @Test func aRecordingThatStopsOnItsOwnKeepsTheFileAndSaysWhy() async throws {
    let failure = CaptureError.recordingStoppedEarly(path: "/tmp/x.mp4", reason: "Failed to find any displays or windows to capture.")
    var handed: [URL] = []
    var events: [RecordingEvent] = []
    let harness = try Harness(
        recorder: FakeRecorder(outcome: failure),
        selection: .area(recordedArea),
        onSaved: { handed.append($0) },
        onRecordingEvent: { events.append($0) }
    )
    await harness.coordinator.toggleRecording(.area)
    await harness.coordinator.stopRecording()
    #expect(handed.count == 1)
    #expect(events.last == .ended(.saved))
    let alert = try #require(harness.alerts.presented.first)
    #expect(alert.title == "Lunetta's recording stopped early")
    #expect(alert.message.contains("Failed to find any displays or windows to capture."))
}

@MainActor @Test func aRecordingWhoseStreamEndsUnaskedEndsOnItsOwnAndKeepsTheFile() async throws {
    var handed: [URL] = []
    var events: [RecordingEvent] = []
    let harness = try Harness(
        recorder: FakeRecorder(endsOnItsOwn: true),
        selection: .area(recordedArea),
        onSaved: { handed.append($0) },
        onRecordingEvent: { events.append($0) }
    )
    await harness.coordinator.toggleRecording(.area)
    #expect(await eventually { handed.count == 1 })
    #expect(events.map(name) == ["started", "ended(saved)"])
    #expect(harness.alerts.presented.isEmpty)
}

@MainActor @Test func theCountdownRunsOverTheSelectionBeforeTheFirstFrame() async throws {
    let recorder = FakeRecorder()
    var startsDuringCountdown: Int?
    let harness = try Harness(recorder: recorder, selection: .area(recordedArea), countsDown: true)
    harness.countdown.during = { startsDuringCountdown = await recorder.starts.count }
    await harness.coordinator.toggleRecording(.area)
    #expect(harness.countdown.shown == [RecordingStatus(region: recordedArea, dimsOutside: true)])
    #expect(startsDuringCountdown == 0)
    #expect(await recorder.starts.count == 1)
    await harness.coordinator.stopRecording()
}

@MainActor @Test func turningTheCountdownOffStartsRightAway() async throws {
    let recorder = FakeRecorder()
    let harness = try Harness(recorder: recorder, selection: .area(recordedArea), countsDown: false)
    await harness.coordinator.toggleRecording(.area)
    #expect(harness.countdown.shown.isEmpty)
    #expect(await recorder.starts.count == 1)
    await harness.coordinator.stopRecording()
}

@MainActor @Test func cancellingTheCountdownRecordsNothing() async throws {
    let recorder = FakeRecorder()
    var events: [RecordingEvent] = []
    let harness = try Harness(recorder: recorder, selection: .area(recordedArea), countsDown: true, onRecordingEvent: { events.append($0) })
    harness.countdown.proceeds = false
    await harness.coordinator.toggleRecording(.area)
    #expect(await recorder.starts.isEmpty)
    #expect(events.isEmpty)
    #expect(harness.alerts.presented.isEmpty)
}

@MainActor @Test func theRecordHotkeyDuringTheCountdownCancelsIt() async throws {
    let recorder = FakeRecorder()
    let harness = try Harness(recorder: recorder, selection: .area(recordedArea), countsDown: true)
    harness.countdown.during = { await harness.coordinator.toggleRecording(.window) }
    await harness.coordinator.toggleRecording(.area)
    #expect(harness.selector.selectionCount == 1)
    #expect(await recorder.starts.isEmpty)
}

@MainActor @Test func pauseAndResumeRecordPartsAndStopJoinsThemIntoTheRecording() async throws {
    let recorder = FakeRecorder()
    var events: [RecordingEvent] = []
    var handed: [URL] = []
    let harness = try Harness(
        recorder: recorder,
        selection: .area(recordedArea),
        onSaved: { handed.append($0) },
        onRecordingEvent: { events.append($0) }
    )
    await harness.coordinator.toggleRecording(.area)
    await harness.coordinator.togglePause()
    #expect(events.last == .paused(RecordingStatus(region: recordedArea, dimsOutside: true, clock: pausedClock())))
    #expect(await recorder.recordings.first?.stopCount == 1)
    await harness.coordinator.togglePause()
    #expect(events.map(name) == ["started", "paused", "resumed"])
    let starts = await recorder.starts
    #expect(starts.count == 2)
    #expect(starts[1].target == starts[0].target && starts[1].options == starts[0].options)
    #expect(starts[1].url.deletingLastPathComponent().standardizedFileURL != harness.folder.standardizedFileURL)

    await harness.coordinator.stopRecording()
    let url = starts[0].url
    #expect(handed == [url])
    let join = try #require(await recorder.joins.first)
    #expect(join.url == url && join.parts.count == 2 && join.parts[1] == starts[1].url)
    #expect(try String(decoding: Data(contentsOf: url), as: UTF8.self) == "part \(url.lastPathComponent);part part-1.mp4;")
    #expect(try harness.savedFiles() == [url.lastPathComponent])
    #expect(!FileManager.default.fileExists(atPath: starts[1].url.deletingLastPathComponent().path))
}

@MainActor @Test func stoppingWhilePausedSavesWhatWasRecordedWithoutAJoin() async throws {
    let recorder = FakeRecorder()
    var handed: [URL] = []
    let harness = try Harness(recorder: recorder, selection: .area(recordedArea), onSaved: { handed.append($0) })
    await harness.coordinator.toggleRecording(.area)
    await harness.coordinator.togglePause()
    await harness.coordinator.stopRecording()
    let firstPart = await recorder.starts[0].url
    #expect(handed == [firstPart])
    #expect(await recorder.joins.isEmpty)
    #expect(await recorder.starts.count == 1)
}

@MainActor @Test func discardStopsTheRecordingAndDeletesEveryPart() async throws {
    let recorder = FakeRecorder()
    var events: [RecordingEvent] = []
    var handed: [URL] = []
    let harness = try Harness(
        recorder: recorder,
        selection: .area(recordedArea),
        onSaved: { handed.append($0) },
        onRecordingEvent: { events.append($0) }
    )
    await harness.coordinator.toggleRecording(.area)
    await harness.coordinator.togglePause()
    await harness.coordinator.togglePause()
    await harness.coordinator.discardRecording()
    #expect(events.map(name) == ["started", "paused", "resumed", "ended(discarded)"])
    #expect(handed.isEmpty)
    #expect(try harness.savedFiles().isEmpty)
    let starts = await recorder.starts
    #expect(!FileManager.default.fileExists(atPath: starts[1].url.deletingLastPathComponent().path))
    for recording in await recorder.recordings {
        #expect(await recording.stopCount == 1)
    }
    #expect(harness.alerts.presented.isEmpty)

    await harness.coordinator.toggleRecording(.area)
    #expect(await recorder.starts.count == 3)
    await harness.coordinator.stopRecording()
}

@MainActor @Test func startOverThrowsAwayWhatWasRecordedAndRecordsTheSameAreaWithTheSameAudioFromZero() async throws {
    let recorder = FakeRecorder()
    var time = recordingStart
    var events: [RecordingEvent] = []
    var handed: [URL] = []
    let harness = try Harness(
        recorder: recorder,
        selection: .area(recordedArea),
        systemAudio: true,
        countsDown: true,
        now: { time },
        onSaved: { handed.append($0) },
        onRecordingEvent: { events.append($0) }
    )
    await harness.coordinator.toggleRecording(.area)
    time += 5
    await harness.coordinator.togglePause()
    await harness.coordinator.togglePause()
    time += 5
    await harness.coordinator.startOverRecording()

    #expect(events.map(name) == ["started", "paused", "resumed", "ended(discarded)", "started"])
    var restarted = RecordingClock()
    restarted.start(at: time)
    #expect(events.last == .started(RecordingStatus(region: recordedArea, dimsOutside: true, clock: restarted)))
    #expect(harness.countdown.shown == Array(repeating: RecordingStatus(region: recordedArea, dimsOutside: true), count: 2))
    #expect(harness.selector.selectionCount == 1)
    let starts = await recorder.starts
    #expect(starts.count == 3)
    #expect(starts[2].target == starts[0].target)
    #expect(starts[2].options == RecordingOptions(codec: .h264, systemAudio: true, microphone: false))
    #expect(try harness.savedFiles().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: starts[1].url.deletingLastPathComponent().path))
    for recording in await recorder.recordings.prefix(2) {
        #expect(await recording.stopCount == 1)
    }

    await harness.coordinator.stopRecording()
    let url = starts[2].url
    #expect(handed == [url])
    #expect(try harness.savedFiles() == [url.lastPathComponent])
    #expect(try String(decoding: Data(contentsOf: url), as: UTF8.self) == "part \(url.lastPathComponent);")
    #expect(await recorder.joins.isEmpty)
    #expect(harness.alerts.presented.isEmpty)
}

@MainActor @Test func startOverWhilePausedThrowsAwayThePausedRecordingAndRecordsAgain() async throws {
    let recorder = FakeRecorder()
    var events: [RecordingEvent] = []
    var handed: [URL] = []
    let harness = try Harness(
        recorder: recorder,
        selection: .area(recordedArea),
        onSaved: { handed.append($0) },
        onRecordingEvent: { events.append($0) }
    )
    await harness.coordinator.toggleRecording(.area)
    await harness.coordinator.togglePause()
    await harness.coordinator.startOverRecording()
    #expect(events.map(name) == ["started", "paused", "ended(discarded)", "started"])
    #expect(events.last == .started(RecordingStatus(region: recordedArea, dimsOutside: true, clock: startedClock())))
    #expect(await recorder.starts.count == 2)
    #expect(try harness.savedFiles().isEmpty)

    await harness.coordinator.togglePause()
    #expect(events.last.map(name) == "paused")
    await harness.coordinator.stopRecording()
    #expect(handed.count == 1)
    #expect(try harness.savedFiles().count == 1)
}

@MainActor @Test func startOverKeepsRecordingTheSameWindow() async throws {
    let window = CapturableWindow(id: 42, frame: CGRect(x: 50, y: 100, width: 400, height: 300))
    let recorder = FakeRecorder()
    var events: [RecordingEvent] = []
    let harness = try Harness(
        capturer: FakeCapturer(windows: [window]),
        recorder: recorder,
        selection: .window(42),
        onRecordingEvent: { events.append($0) }
    )
    await harness.coordinator.toggleRecording(.window)
    await harness.coordinator.startOverRecording()
    #expect(await recorder.starts.map { $0.target } == [.window(42), .window(42)])
    #expect(harness.selector.selectionCount == 1)
    let frame = CGRect(x: 50, y: 982 - 400, width: 400, height: 300)
    #expect(events.last == .started(RecordingStatus(region: frame, dimsOutside: false, clock: startedClock())))
    await harness.coordinator.stopRecording()
}

@MainActor @Test func cancellingTheCountdownWhenStartingOverLeavesNoRecording() async throws {
    let recorder = FakeRecorder()
    var events: [RecordingEvent] = []
    let harness = try Harness(recorder: recorder, selection: .area(recordedArea), countsDown: true, onRecordingEvent: { events.append($0) })
    await harness.coordinator.toggleRecording(.area)
    harness.countdown.proceeds = false
    await harness.coordinator.startOverRecording()
    #expect(events.map(name) == ["started", "ended(discarded)"])
    #expect(await recorder.starts.count == 1)
    #expect(try harness.savedFiles().isEmpty)
    #expect(harness.alerts.presented.isEmpty)

    harness.countdown.proceeds = true
    await harness.coordinator.toggleRecording(.area)
    #expect(await recorder.starts.count == 2)
    await harness.coordinator.stopRecording()
}

@MainActor @Test func aStartOverThatFailsToStartSaysWhyAndLeavesNothing() async throws {
    let failure = CaptureError.recordingFailed(path: "/tmp/x.mp4", reason: "Start stream failed")
    var events: [RecordingEvent] = []
    let harness = try Harness(
        recorder: FakeRecorder(startFailure: failure, failingStart: 2),
        selection: .area(recordedArea),
        onRecordingEvent: { events.append($0) }
    )
    await harness.coordinator.toggleRecording(.area)
    await harness.coordinator.startOverRecording()
    #expect(events.map(name) == ["started", "ended(discarded)", "started", "ended(failed)"])
    let alert = try #require(harness.alerts.presented.first)
    #expect(alert.title == "Lunetta couldn't start the recording over")
    #expect(alert.message == failure.localizedDescription)
    #expect(try harness.savedFiles().isEmpty)
}

@MainActor @Test func aResumeThatFailsSavesWhatCameBeforeAndSaysWhy() async throws {
    let failure = CaptureError.recordingFailed(path: "/tmp/part-1.mp4", reason: "Start stream failed")
    var events: [RecordingEvent] = []
    var handed: [URL] = []
    let recorder = FakeRecorder(startFailure: failure, failingStart: 2)
    let harness = try Harness(
        recorder: recorder,
        selection: .area(recordedArea),
        onSaved: { handed.append($0) },
        onRecordingEvent: { events.append($0) }
    )
    await harness.coordinator.toggleRecording(.area)
    await harness.coordinator.togglePause()
    await harness.coordinator.togglePause()
    #expect(events.map(name) == ["started", "paused", "ended(saved)"])
    let firstPart = await recorder.starts[0].url
    #expect(handed == [firstPart])
    let alert = try #require(harness.alerts.presented.first)
    #expect(alert.title == "Lunetta couldn't finish the recording")
    #expect(alert.message == failure.localizedDescription)
}

@MainActor @Test func aJoinThatFailsKeepsTheFirstPartAndSaysWhy() async throws {
    let failure = CaptureError.recordingFailed(path: "/tmp/x.mp4", reason: "Cannot Open")
    var handed: [URL] = []
    let recorder = FakeRecorder(joinFailure: failure)
    let harness = try Harness(recorder: recorder, selection: .area(recordedArea), onSaved: { handed.append($0) })
    await harness.coordinator.toggleRecording(.area)
    await harness.coordinator.togglePause()
    await harness.coordinator.togglePause()
    await harness.coordinator.stopRecording()
    let url = await recorder.starts[0].url
    #expect(handed == [url])
    #expect(try String(decoding: Data(contentsOf: url), as: UTF8.self) == "part \(url.lastPathComponent);")
    #expect(harness.alerts.presented.first?.message == failure.localizedDescription)
}

@MainActor @Test func pauseDiscardAndStartOverDoNothingWithoutARecording() async throws {
    var events: [RecordingEvent] = []
    let harness = try Harness(selection: .cancelled, onRecordingEvent: { events.append($0) })
    await harness.coordinator.togglePause()
    await harness.coordinator.discardRecording()
    await harness.coordinator.startOverRecording()
    await harness.coordinator.stopRecording()
    #expect(events.isEmpty)
}

@MainActor @Test func recordingWhileAnOverlayIsUpStartsNothing() async throws {
    let recorder = FakeRecorder()
    let harness = try Harness(recorder: recorder, selection: .area(CGRect(x: 10, y: 10, width: 5, height: 5)))
    harness.selector.whileSelecting = { await harness.coordinator.toggleRecording(.area) }
    await harness.coordinator.run(.area)
    #expect(harness.selector.selectionCount == 1)
    #expect(await recorder.starts.isEmpty)
}

@MainActor @Test(arguments: [(false, false), (true, false), (false, true), (true, true)])
func recordingAsksForExactlyTheAudioStreamsThatAreOn(systemAudio: Bool, microphone: Bool) async throws {
    let recorder = FakeRecorder()
    let harness = try Harness(recorder: recorder, selection: .area(recordedArea), systemAudio: systemAudio, recordMicrophone: microphone)
    await harness.coordinator.toggleRecording(.area)
    let options = try #require(await recorder.starts.first?.options)
    #expect(options.systemAudio == systemAudio)
    #expect(options.microphone == microphone)
    await harness.coordinator.stopRecording()
}

private let deskMic = AudioInput(id: "usb-1", name: "Desk Mic")

@MainActor @Test func theChosenInputReachesTheRecorder() async throws {
    let recorder = FakeRecorder()
    let harness = try Harness(
        recorder: recorder,
        microphone: FakeMicrophone(inputs: [deskMic]),
        selection: .area(recordedArea),
        recordMicrophone: true,
        input: deskMic
    )
    await harness.coordinator.toggleRecording(.area)
    let options = try #require(await recorder.starts.first?.options)
    #expect(options == RecordingOptions(codec: .h264, systemAudio: false, microphone: true, microphoneID: "usb-1"))
    await harness.coordinator.stopRecording()
    #expect(harness.alerts.presented.isEmpty)
}

@MainActor @Test func clickRingsShowOverTheAreaStayInTheRecordingAndGoWhenItEnds() async throws {
    let recorder = FakeRecorder()
    let harness = try Harness(recorder: recorder, selection: .area(recordedArea), showsClicks: true)
    await harness.coordinator.toggleRecording(.area)
    #expect(harness.clickRings.shownOver == [recordedArea])
    let options = try #require(await recorder.starts.first?.options)
    #expect(!options.showsClicks, "macOS's circles drew nothing in area recordings, and would double up with the rings if they ever did")
    await harness.coordinator.togglePause()
    await harness.coordinator.togglePause()
    #expect(harness.clickRings.hideCount == 0)
    await harness.coordinator.stopRecording()
    #expect(harness.clickRings.hideCount == 1)
}

@MainActor @Test func aWindowRecordingLeavesClicksToMacOS() async throws {
    let window = CapturableWindow(id: 42, frame: CGRect(x: 50, y: 100, width: 400, height: 300))
    let recorder = FakeRecorder()
    let harness = try Harness(capturer: FakeCapturer(windows: [window]), recorder: recorder, selection: .window(42), showsClicks: true)
    await harness.coordinator.toggleRecording(.window)
    #expect(harness.clickRings.shownOver.isEmpty)
    let options = try #require(await recorder.starts.first?.options)
    #expect(options.showsClicks)
    await harness.coordinator.stopRecording()
}

@MainActor @Test func aRecordingThatCantStartTakesTheClickRingsDown() async throws {
    let failure = CaptureError.recordingFailed(path: "/tmp/x.mp4", reason: "Start stream failed")
    let harness = try Harness(recorder: FakeRecorder(startFailure: failure), selection: .area(recordedArea), showsClicks: true)
    await harness.coordinator.toggleRecording(.area)
    #expect(harness.clickRings.hideCount == 1)
}

@MainActor @Test func theCameraShowsInTheAreaStaysThroughPausesAndGoesWhenTheRecordingEnds() async throws {
    let harness = try Harness(selection: .area(recordedArea), recordCamera: true, cameraInput: deskCam)
    await harness.coordinator.toggleRecording(.area)
    #expect(harness.camera.shown.map(\.region) == [recordedArea])
    #expect(harness.camera.shown.map(\.camera) == [deskCam])
    await harness.coordinator.togglePause()
    await harness.coordinator.togglePause()
    #expect(harness.camera.hideCount == 0)
    await harness.coordinator.stopRecording()
    #expect(harness.camera.hideCount == 1)
    #expect(harness.alerts.presented.isEmpty)
}

@MainActor @Test func theCameraShowsDuringTheCountdownSoTheUserCanSeeThemselvesFirst() async throws {
    let harness = try Harness(selection: .area(recordedArea), recordCamera: true, countsDown: true)
    var shownDuringCountdown = 0
    harness.countdown.during = { shownDuringCountdown = harness.camera.shown.count }
    await harness.coordinator.toggleRecording(.area)
    #expect(shownDuringCountdown == 1)
    #expect(harness.camera.shown.map(\.camera) == [nil], "System Default shows the system's camera")
    await harness.coordinator.stopRecording()
}

@MainActor @Test func aChosenCameraIsIgnoredWhileTheCameraIsOff() async throws {
    let harness = try Harness(selection: .area(recordedArea), cameraInput: deskCam)
    await harness.coordinator.toggleRecording(.area)
    #expect(harness.camera.shown.isEmpty)
    await harness.coordinator.stopRecording()
}

@MainActor @Test func startingOverBringsTheCameraBack() async throws {
    let harness = try Harness(selection: .area(recordedArea), recordCamera: true)
    await harness.coordinator.toggleRecording(.area)
    await harness.coordinator.startOverRecording()
    #expect(harness.camera.shown.map(\.region) == [recordedArea, recordedArea])
    await harness.coordinator.stopRecording()
}

@MainActor @Test func aCameraThatCantShowKeepsTheRecordingFromStartingAndSaysWhy() async throws {
    let recorder = FakeRecorder()
    let camera = FakeCamera()
    camera.refusal = .refused("Desk Cam")
    let harness = try Harness(recorder: recorder, camera: camera, selection: .area(recordedArea), recordCamera: true, cameraInput: deskCam, showsKeys: true)
    await harness.coordinator.toggleRecording(.area)
    #expect(await recorder.starts.isEmpty)
    let alert = try #require(harness.alerts.presented.first)
    #expect(alert.message.contains("\"Desk Cam\""))
    #expect(harness.keystrokes.hideCount == 1, "the keys shown before the camera failed stayed up")
}

@MainActor @Test func aWindowRecordingWithTheCameraOnRecordsTheWindowInPlaceWithTheCameraOverIt() async throws {
    let window = CapturableWindow(id: 42, frame: CGRect(x: 50, y: 100, width: 400, height: 300))
    let recorder = FakeRecorder()
    let harness = try Harness(capturer: FakeCapturer(windows: [window]), recorder: recorder, selection: .window(42), recordCamera: true)
    await harness.coordinator.toggleRecording(.window)
    let frame = CGRect(x: 50, y: 982 - 400, width: 400, height: 300)
    #expect(await recorder.starts.first?.target == .windowInPlace(42, frame: frame, on: mainDisplay))
    #expect(harness.camera.shown.map { $0.0 } == [frame])
    #expect(harness.alerts.presented.isEmpty)
    await harness.coordinator.stopRecording()
    #expect(harness.camera.hideCount == 1)
}

@MainActor @Test func cameraAccessIsAskedForFromTheAlert() async throws {
    let camera = FakeCamera(.notDetermined)
    let harness = try Harness(camera: camera, selection: .area(recordedArea), recordCamera: true)
    harness.alerts.answer = .allowCamera
    await harness.coordinator.toggleRecording(.area)
    #expect(harness.alerts.presented.first?.buttons == [.allowCamera, .ok])
    await harness.coordinator.fix(.openCameraSettings)
    #expect(camera.settingsOpened == 1)
    await harness.coordinator.fix(.allowCamera)
    #expect(camera.requestCount >= 1)
    #expect(harness.coordinator.recordingProblems().isEmpty)
}

@MainActor @Test func aChosenInputIsIgnoredWhileTheMicrophoneIsOff() async throws {
    let recorder = FakeRecorder()
    let harness = try Harness(recorder: recorder, selection: .area(recordedArea), input: deskMic)
    await harness.coordinator.toggleRecording(.area)
    let options = try #require(await recorder.starts.first?.options)
    #expect(options.microphoneID == nil)
    #expect(!options.microphone)
    await harness.coordinator.stopRecording()
}

@MainActor @Test func pressedKeysShowOverTheAreaStayInTheRecordingAndGoWhenItEnds() async throws {
    let recorder = FakeRecorder()
    let harness = try Harness(recorder: recorder, selection: .area(recordedArea), showsKeys: true)
    await harness.coordinator.toggleRecording(.area)
    #expect(harness.keystrokes.shownOver == [recordedArea])
    #expect(harness.keystrokes.hideCount == 0)
    await harness.coordinator.togglePause()
    await harness.coordinator.togglePause()
    #expect(harness.keystrokes.hideCount == 0)
    await harness.coordinator.stopRecording()
    #expect(harness.keystrokes.hideCount == 1)
}

@MainActor @Test func withoutPressedKeysNoOverlayShowsOrStaysInTheRecording() async throws {
    let recorder = FakeRecorder()
    let harness = try Harness(recorder: recorder, selection: .area(recordedArea))
    await harness.coordinator.toggleRecording(.area)
    #expect(harness.keystrokes.shownOver.isEmpty)
    await harness.coordinator.stopRecording()
}

@MainActor @Test func cancellingTheCountdownTakesThePressedKeysDown() async throws {
    let recorder = FakeRecorder()
    let harness = try Harness(recorder: recorder, selection: .area(recordedArea), showsKeys: true, countsDown: true)
    harness.countdown.proceeds = false
    await harness.coordinator.toggleRecording(.area)
    #expect(await recorder.starts.isEmpty)
    #expect(harness.keystrokes.hideCount == 1)
}

@MainActor @Test func aRecordingThatCantStartTakesThePressedKeysDown() async throws {
    let failure = CaptureError.recordingFailed(path: "/tmp/x.mp4", reason: "Start stream failed")
    let harness = try Harness(recorder: FakeRecorder(startFailure: failure), selection: .area(recordedArea), showsKeys: true)
    await harness.coordinator.toggleRecording(.area)
    #expect(harness.keystrokes.hideCount == 1)
    let alert = try #require(harness.alerts.presented.first)
    #expect(alert.message == failure.localizedDescription)
}

@MainActor @Test func inputMonitoringRevokedWhileStagedFailsLoudlyAndRecordsNothing() async throws {
    let recorder = FakeRecorder()
    let keystrokes = FakeKeystrokes()
    var events: [RecordingEvent] = []
    let harness = try Harness(
        recorder: recorder,
        keystrokes: keystrokes,
        selection: .area(recordedArea),
        showsKeys: true,
        onRecordingEvent: { events.append($0) }
    )
    harness.stager.whileStaged = { keystrokes.isAllowed = false }
    await harness.coordinator.toggleRecording(.area)
    #expect(await recorder.starts.isEmpty)
    #expect(events.isEmpty)
    #expect(keystrokes.shownOver.isEmpty)
    let alert = try #require(harness.alerts.presented.first)
    #expect(alert.message.contains("Input Monitoring"))
    #expect(alert.buttons == [.openInputMonitoringSettings, .ok])
}

@MainActor private func alertBlockingTheRecording(_ harness: Harness, recorder: FakeRecorder) async throws -> CaptureAlert {
    await harness.coordinator.toggleRecording(.area)
    #expect(harness.stager.staged.count == 1, "the stage is where the problem shows, so it has to come up")
    #expect(await recorder.starts.isEmpty)
    let alert = try #require(harness.alerts.presented.first)
    #expect(alert.title == "Lunetta couldn't start the recording")
    return alert
}

@MainActor @Test func microphoneOnWithoutPermissionAlertsAfterTheStageAndRecordsNothing() async throws {
    let recorder = FakeRecorder()
    let harness = try Harness(recorder: recorder, microphone: FakeMicrophone(.denied), selection: .area(recordedArea), recordMicrophone: true)
    let alert = try await alertBlockingTheRecording(harness, recorder: recorder)
    #expect(alert.message == RecordingProblem.microphoneDenied.localizedDescription)
    #expect(alert.message.contains("System Settings > Privacy & Security > Microphone"))
    #expect(alert.buttons == [.openMicrophoneSettings, .ok])
}

@MainActor @Test func microphoneOnBeforeMacOSAskedOffersToAsk() async throws {
    let recorder = FakeRecorder()
    let harness = try Harness(recorder: recorder, microphone: FakeMicrophone(.notDetermined), selection: .area(recordedArea), recordMicrophone: true)
    let alert = try await alertBlockingTheRecording(harness, recorder: recorder)
    #expect(alert.message == RecordingProblem.microphoneNotAllowedYet.localizedDescription)
    #expect(alert.buttons == [.allowMicrophone, .ok])
}

@MainActor @Test func aChosenInputThatIsUnpluggedIsNamedAndNothingRecords() async throws {
    let recorder = FakeRecorder()
    let harness = try Harness(recorder: recorder, microphone: FakeMicrophone(inputs: []), selection: .area(recordedArea), recordMicrophone: true, input: deskMic)
    let alert = try await alertBlockingTheRecording(harness, recorder: recorder)
    #expect(alert.message.contains("\"Desk Mic\" isn't connected"))
    #expect(alert.buttons == [.ok])
}

@MainActor @Test func pressedKeysWithoutInputMonitoringPointToItsSettings() async throws {
    let recorder = FakeRecorder()
    let harness = try Harness(recorder: recorder, keystrokes: FakeKeystrokes(allowed: false), selection: .area(recordedArea), showsKeys: true)
    let alert = try await alertBlockingTheRecording(harness, recorder: recorder)
    #expect(alert.message.contains("System Settings > Privacy & Security > Input Monitoring"))
    #expect(alert.buttons == [.openInputMonitoringSettings, .ok])
    #expect(harness.keystrokes.shownOver.isEmpty)
}

@MainActor @Test func pressedKeysRecordAWindowInPlaceAndBringLunettasClickRingsAlong() async throws {
    let window = CapturableWindow(id: 42, frame: CGRect(x: 50, y: 100, width: 400, height: 300))
    let recorder = FakeRecorder()
    let harness = try Harness(capturer: FakeCapturer(windows: [window]), recorder: recorder, selection: .window(42), showsKeys: true, showsClicks: true)
    await harness.coordinator.toggleRecording(.window)
    let frame = CGRect(x: 50, y: 982 - 400, width: 400, height: 300)
    let start = try #require(await recorder.starts.first)
    #expect(start.target == .windowInPlace(42, frame: frame, on: mainDisplay))
    #expect(harness.keystrokes.shownOver == [frame])
    #expect(harness.clickRings.shownOver == [frame], "the rings are in the recording now, so macOS's circles shouldn't double them")
    #expect(!start.options.showsClicks)
    await harness.coordinator.stopRecording()
}

@MainActor @Test func theAlertButtonsDoWhatTheySay() async throws {
    let asking = try Harness(microphone: FakeMicrophone(.notDetermined), selection: .area(recordedArea), recordMicrophone: true)
    asking.alerts.answer = .allowMicrophone
    await asking.coordinator.toggleRecording(.area)
    #expect(await eventually { asking.microphone.requestCount == 1 })

    let denied = try Harness(microphone: FakeMicrophone(.denied), selection: .area(recordedArea), recordMicrophone: true)
    denied.alerts.answer = .openMicrophoneSettings
    await denied.coordinator.toggleRecording(.area)
    #expect(denied.microphone.settingsOpened == 1)

    let keys = try Harness(keystrokes: FakeKeystrokes(allowed: false), selection: .area(recordedArea), showsKeys: true)
    keys.alerts.answer = .openInputMonitoringSettings
    await keys.coordinator.toggleRecording(.area)
    #expect(keys.keystrokes.settingsOpened == 1)
}

@MainActor @Test func thePanelsFixesAskOrOpenTheRightSettings() async throws {
    let harness = try Harness(microphone: FakeMicrophone(.notDetermined), selection: .cancelled)
    await harness.coordinator.fix(.allowMicrophone)
    #expect(harness.microphone.requestCount == 1)
    await harness.coordinator.fix(.openMicrophoneSettings)
    #expect(harness.microphone.settingsOpened == 1)
    await harness.coordinator.fix(.openInputMonitoringSettings)
    #expect(harness.keystrokes.settingsOpened == 1)
}

@MainActor @Test func thePanelSeesEveryProblemTheCurrentChoicesHave() async throws {
    let harness = try Harness(
        microphone: FakeMicrophone(.denied, inputs: []),
        keystrokes: FakeKeystrokes(allowed: false),
        selection: .cancelled,
        recordMicrophone: true,
        input: deskMic,
        showsKeys: true
    )
    #expect(harness.coordinator.recordingProblems() == [.microphoneDenied, .inputMissing(deskMic), .inputMonitoringDenied])
}

@MainActor @Test func losingTheChosenInputEndsTheRecordingKeepsTheFileAndNamesTheInput() async throws {
    var handed: [URL] = []
    var events: [RecordingEvent] = []
    let harness = try Harness(
        microphone: FakeMicrophone(inputs: [deskMic]),
        selection: .area(recordedArea),
        recordMicrophone: true,
        input: deskMic,
        onSaved: { handed.append($0) },
        onRecordingEvent: { events.append($0) }
    )
    await harness.coordinator.toggleRecording(.area)
    await harness.coordinator.inputDisconnected(id: deskMic.id)
    #expect(events.map(name) == ["started", "ended(saved)"])
    let saved = try #require(handed.first)
    let alert = try #require(harness.alerts.presented.first)
    #expect(alert.title == "Lunetta's recording stopped early")
    #expect(alert.message == InputDisconnected.message(input: deskMic, savedTo: saved.path))
}

@MainActor @Test func losingAnInputTheRecordingDoesntUseChangesNothing() async throws {
    var events: [RecordingEvent] = []
    let harness = try Harness(
        microphone: FakeMicrophone(inputs: [deskMic]),
        selection: .area(recordedArea),
        recordMicrophone: true,
        input: deskMic,
        onRecordingEvent: { events.append($0) }
    )
    await harness.coordinator.toggleRecording(.area)
    await harness.coordinator.inputDisconnected(id: "another-mic")
    #expect(events.map(name) == ["started"])

    var defaultEvents: [RecordingEvent] = []
    let followsDefault = try Harness(selection: .area(recordedArea), recordMicrophone: true, onRecordingEvent: { defaultEvents.append($0) })
    await followsDefault.coordinator.toggleRecording(.area)
    await followsDefault.coordinator.inputDisconnected(id: deskMic.id)
    #expect(defaultEvents.map(name) == ["started"])
    await harness.coordinator.stopRecording()
    await followsDefault.coordinator.stopRecording()
    #expect(harness.alerts.presented.isEmpty && followsDefault.alerts.presented.isEmpty)
}

@MainActor @Test func startOverBringsTheOverlaysBackAndKeepsTheChosenInput() async throws {
    let recorder = FakeRecorder()
    var events: [RecordingEvent] = []
    let harness = try Harness(
        recorder: recorder,
        microphone: FakeMicrophone(inputs: [deskMic]),
        selection: .area(recordedArea),
        recordMicrophone: true,
        input: deskMic,
        showsKeys: true,
        showsClicks: true,
        onRecordingEvent: { events.append($0) }
    )
    await harness.coordinator.toggleRecording(.area)
    await harness.coordinator.startOverRecording()
    #expect(harness.keystrokes.shownOver == [recordedArea, recordedArea])
    #expect(harness.keystrokes.hideCount == 1, "the discarded recording should take its keys down once, and the new one keep them up")
    #expect(harness.clickRings.shownOver == [recordedArea, recordedArea])
    #expect(harness.clickRings.hideCount == 1)
    let options = await recorder.starts.map { $0.options }
    #expect(options.count == 2)
    #expect(options.last?.microphoneID == deskMic.id)
    await harness.coordinator.inputDisconnected(id: deskMic.id)
    #expect(events.last == .ended(.saved))
    #expect(harness.alerts.presented.first?.message.contains("\"Desk Mic\" was disconnected") == true)
}

@MainActor @Test func recordAreaRecordsTheAreaAsItWasLeftOnTheStage() async throws {
    let recorder = FakeRecorder()
    var events: [RecordingEvent] = []
    let adjusted = CGRect(x: 120, y: 180, width: 350, height: 200)
    let harness = try Harness(recorder: recorder, selection: .area(recordedArea), onRecordingEvent: { events.append($0) })
    harness.stager.answer = { _ in adjusted }
    await harness.coordinator.toggleRecording(.area)
    #expect(harness.stager.staged.map(\.region) == [recordedArea])
    #expect(harness.stager.staged.map(\.display) == [mainDisplay])
    #expect(harness.stager.staged.map(\.mode) == [.area])
    #expect(await recorder.starts.first?.target == .area(adjusted, on: mainDisplay))
    #expect(events == [.started(RecordingStatus(region: adjusted, dimsOutside: true, clock: startedClock()))])
    await harness.coordinator.stopRecording()
}

@MainActor @Test func droppingTheStageRecordsNothingAndSaysNothing() async throws {
    let recorder = FakeRecorder()
    var events: [RecordingEvent] = []
    let harness = try Harness(recorder: recorder, selection: .area(recordedArea), onRecordingEvent: { events.append($0) })
    harness.stager.answer = { _ in nil }
    await harness.coordinator.toggleRecording(.area)
    #expect(await recorder.starts.isEmpty)
    #expect(events.isEmpty)
    #expect(harness.alerts.presented.isEmpty)
}

@MainActor @Test func aMissingPermissionWaitsForTheStageInsteadOfAlertingBeforeIt() async throws {
    let recorder = FakeRecorder()
    let harness = try Harness(recorder: recorder, microphone: FakeMicrophone(.denied), selection: .area(recordedArea), recordMicrophone: true)
    await harness.coordinator.toggleRecording(.area)
    #expect(harness.stager.staged.count == 1, "the stage is where the problem shows, so it has to come up")
    #expect(await recorder.starts.isEmpty)
    let alert = try #require(harness.alerts.presented.first, "a problem still there after the stage must not record silently")
    #expect(alert.message == RecordingProblem.microphoneDenied.localizedDescription)
    #expect(alert.buttons == [.openMicrophoneSettings, .ok])
}

@MainActor @Test func aProblemFixedOnTheStageRecords() async throws {
    let recorder = FakeRecorder()
    let harness = try Harness(recorder: recorder, microphone: FakeMicrophone(.denied), selection: .area(recordedArea), recordMicrophone: true)
    harness.stager.whileStaged = { harness.settings.recordMicrophone = false }
    await harness.coordinator.toggleRecording(.area)
    #expect(await recorder.starts.first?.options.microphone == false)
    #expect(harness.alerts.presented.isEmpty)
    await harness.coordinator.stopRecording()
}

@MainActor @Test func recordWindowStagesThePickedWindowThenRecordsIt() async throws {
    let window = CapturableWindow(id: 42, frame: CGRect(x: 50, y: 100, width: 400, height: 300))
    let recorder = FakeRecorder()
    let harness = try Harness(capturer: FakeCapturer(windows: [window]), recorder: recorder, selection: .window(42))
    await harness.coordinator.toggleRecording(.window)
    let frame = CGRect(x: 50, y: 982 - 400, width: 400, height: 300)
    #expect(harness.stager.staged.map(\.region) == [frame])
    #expect(harness.stager.staged.map(\.display) == [mainDisplay])
    #expect(harness.stager.staged.map(\.mode) == [.window])
    #expect(await recorder.starts.first?.target == .window(42))
    await harness.coordinator.stopRecording()
}

@MainActor @Test func droppingTheWindowStageRecordsNothing() async throws {
    let window = CapturableWindow(id: 42, frame: CGRect(x: 50, y: 100, width: 400, height: 300))
    let recorder = FakeRecorder()
    let harness = try Harness(capturer: FakeCapturer(windows: [window]), recorder: recorder, selection: .window(42))
    harness.stager.answer = { _ in nil }
    await harness.coordinator.toggleRecording(.window)
    #expect(await recorder.starts.isEmpty)
    #expect(harness.alerts.presented.isEmpty)
}

@MainActor @Test func theRecordShortcutStopsARunningRecording() async throws {
    let recorder = FakeRecorder()
    var handed: [URL] = []
    let harness = try Harness(recorder: recorder, selection: .area(recordedArea), onSaved: { handed.append($0) })
    await harness.coordinator.toggleRecording(.area)
    await harness.coordinator.toggleRecording(.area)
    #expect(await recorder.starts.count == 1)
    #expect(harness.stager.staged.count == 1)
    #expect(handed.count == 1)
}

@MainActor
private final class OrderLog {
    var entries: [String] = []
    func append(_ entry: String) { entries.append(entry) }
}

private let scrollArea = CGRect(x: 100, y: 100, width: 32, height: 200)
private let scrollFrameHeight = 400

private func scrollPage(width: Int = 64, height: Int) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    var state: UInt32 = 0x9E37_79B9
    for row in 0..<height {
        for column in stride(from: 0, to: width, by: 8) {
            state = state &* 1_664_525 &+ 1_013_904_223
            context.setFillColor(red: CGFloat(state >> 24) / 255, green: CGFloat((state >> 16) & 0xFF) / 255, blue: CGFloat((state >> 8) & 0xFF) / 255, alpha: 1)
            context.fill(CGRect(x: column, y: height - row - 1, width: 8, height: 1))
        }
    }
    return context.makeImage()!
}

private func scrolledFrames(tops: [Int]) -> [CGImage] {
    let page = scrollPage(height: tops.max()! + scrollFrameHeight)
    return tops.map { page.cropping(to: CGRect(x: 0, y: $0, width: page.width, height: scrollFrameHeight))! }
}

@MainActor
private func savedImage(_ harness: Harness) throws -> CGImage {
    let name = try #require(try harness.savedFiles().first)
    let source = try #require(CGImageSourceCreateWithURL(harness.folder.appending(path: name) as CFURL, nil))
    return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
}

@MainActor @Test func scrollingDoneWritesOneTallPNG() async throws {
    let stager = FakeScrollStager()
    stager.expectedShows = 2
    let capturer = FakeCapturer(scrollFrames: scrolledFrames(tops: [0, 40, 80]))
    let harness = try Harness(capturer: capturer, scrollStager: stager, selection: .area(scrollArea))
    await harness.coordinator.run(.scrolling)
    #expect(try harness.savedFiles().count == 1)
    #expect(try savedImage(harness).height == scrollFrameHeight + 80)
    #expect(await capturer.scrollStopCount == 1)
    #expect(harness.alerts.presented.isEmpty)
}

@MainActor @Test func scrollingWithoutScrollMatchesAreaCapture() async throws {
    let frame = scrolledFrames(tops: [0])[0]
    let harness = try Harness(capturer: FakeCapturer(scrollFrames: [frame]), selection: .area(scrollArea))
    await harness.coordinator.run(.scrolling)
    let saved = try savedImage(harness)
    #expect(saved.width == frame.width && saved.height == frame.height)
    #expect(Frame(saved)?.pixels == Frame(frame)?.pixels)
}

@MainActor @Test func scrollingCancelWritesNothing() async throws {
    let stager = FakeScrollStager(.cancelled)
    stager.expectedShows = 2
    let capturer = FakeCapturer(scrollFrames: scrolledFrames(tops: [0, 40, 80]))
    let harness = try Harness(capturer: capturer, scrollStager: stager, selection: .area(scrollArea))
    await harness.coordinator.run(.scrolling)
    #expect(try harness.savedFiles().isEmpty)
    #expect(await capturer.scrollStopCount == 1)
    #expect(harness.alerts.presented.isEmpty)
}

@MainActor @Test func scrollingSelectionCancelWritesNothing() async throws {
    let capturer = FakeCapturer(scrollFrames: scrolledFrames(tops: [0]))
    let harness = try Harness(capturer: capturer, selection: .cancelled)
    await harness.coordinator.run(.scrolling)
    #expect(harness.scrollStager.prepared.isEmpty)
    #expect(harness.scrollStager.shown.isEmpty)
    #expect(try harness.savedFiles().isEmpty)
    #expect(await capturer.scrollStopCount == 0)
}

@MainActor @Test func scrollingIgnoresFreezeScreen() async throws {
    let capturer = FakeCapturer(scrollFrames: scrolledFrames(tops: [0]))
    let harness = try Harness(capturer: capturer, selection: .area(scrollArea), freezeOn: true)
    await harness.coordinator.run(.scrolling)
    #expect(harness.selector.selectionCount == 1)
    #expect(harness.selector.frozenDisplayIDs.isEmpty)
    #expect(await capturer.capturedDisplayIDs.isEmpty)
    #expect(try harness.savedFiles().count == 1)
}

@MainActor @Test func scrollingStreamFailureSavesNothing() async throws {
    let stager = FakeScrollStager(nil)
    let capturer = FakeCapturer(scrollFrames: scrolledFrames(tops: [0, 40]), scrollError: .permissionDenied)
    let harness = try Harness(capturer: capturer, scrollStager: stager, selection: .area(scrollArea))
    await harness.coordinator.run(.scrolling)
    #expect(stager.dismissCount == 1)
    #expect(harness.alerts.presented.count == 1)
    #expect(harness.alerts.presented.first?.message == CaptureError.permissionDenied.localizedDescription)
    #expect(try harness.savedFiles().isEmpty)
    #expect(await capturer.scrollStopCount == 1)
}

@MainActor @Test func scrollingStreamStartFailureDismissesStage() async throws {
    let capturer = FakeCapturer(scrollStartError: .displayNotFound(1))
    let harness = try Harness(capturer: capturer, selection: .area(scrollArea))
    await harness.coordinator.run(.scrolling)
    #expect(harness.scrollStager.dismissCount == 1)
    #expect(harness.alerts.presented.count == 1)
    #expect(try harness.savedFiles().isEmpty)
}

@MainActor @Test func scrollingPreparesStageBeforeStream() async throws {
    let order = OrderLog()
    let stager = FakeScrollStager()
    stager.onPrepare = { order.entries.append("prepare") }
    let capturer = FakeCapturer(scrollFrames: scrolledFrames(tops: [0]), onScrollingFrames: { await order.append("stream") })
    let harness = try Harness(capturer: capturer, scrollStager: stager, selection: .area(scrollArea))
    await harness.coordinator.run(.scrolling)
    #expect(order.entries == ["prepare", "stream"])
    #expect(stager.prepared.first?.area == scrollArea)
    #expect(stager.prepared.first?.display == mainDisplay)
}

@MainActor @Test func scrollingShowsUpdatesOnStage() async throws {
    let stager = FakeScrollStager()
    stager.expectedShows = 2
    let capturer = FakeCapturer(scrollFrames: scrolledFrames(tops: [0, 40, 80]))
    let harness = try Harness(capturer: capturer, scrollStager: stager, selection: .area(scrollArea))
    await harness.coordinator.run(.scrolling)
    #expect(stager.shown.count == 2)
    #expect(stager.shown.last?.update.height == scrollFrameHeight + 80)
    #expect(stager.shown.last?.preview?.height == stager.previewPixelHeight)
}
