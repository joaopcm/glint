import CoreGraphics
import Foundation
import GlintCapture
import GlintCore
import Testing
@testable import Glint

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
    private(set) var capturedDisplayIDs: [UInt32] = []
    private(set) var capturedWindowIDs: [UInt32] = []
    private(set) var windowListServed = false
    private(set) var areaCaptureCount = 0

    init(
        displays: [DisplayInfo] = [mainDisplay],
        failure: CaptureError? = nil,
        permissionGranted: Bool = true,
        windowListGate: Gate? = nil,
        windows: [CapturableWindow] = []
    ) {
        displayList = displays
        self.windows = windows
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

    func captureWindow(id: UInt32) async throws -> CGImage {
        capturedWindowIDs.append(id)
        return try image()
    }

    func shareableWindows() async throws -> [CapturableWindow] {
        await windowListGate?.wait()
        windowListServed = true
        if let failure { throw failure }
        return windows
    }

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

    init(url: URL, outcome: CaptureError?) {
        self.url = url
        self.outcome = outcome
    }

    func stop() async {
        stopCount += 1
        await stopGate.open()
    }

    func finished() async throws {
        await stopGate.wait()
        FileManager.default.createFile(atPath: url.path, contents: Data("mp4".utf8))
        if let outcome { throw outcome }
    }
}

private actor FakeRecorder: Recording {
    let startFailure: CaptureError?
    let outcome: CaptureError?
    private(set) var starts: [(target: RecordingTarget, url: URL, options: RecordingOptions)] = []
    private(set) var recordings: [FakeRecording] = []

    init(startFailure: CaptureError? = nil, outcome: CaptureError? = nil) {
        self.startFailure = startFailure
        self.outcome = outcome
    }

    func startRecording(_ target: RecordingTarget, to url: URL, options: RecordingOptions) async throws -> any ActiveRecording {
        if let startFailure { throw startFailure }
        starts.append((target, url, options))
        let recording = FakeRecording(url: url, outcome: outcome)
        recordings.append(recording)
        return recording
    }
}

@MainActor
private final class FakeMicrophone: MicrophoneAccess {
    var status: MicrophoneStatus
    let grants: Bool
    private(set) var requestCount = 0
    private(set) var settingsOpened = 0

    init(_ status: MicrophoneStatus = .authorized, grants: Bool = true) {
        self.status = status
        self.grants = grants
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
    let settings: GlintSettings
    let microphone: FakeMicrophone
    let coordinator: CaptureCoordinator

    init(
        capturer: FakeCapturer = FakeCapturer(),
        recorder: FakeRecorder = FakeRecorder(),
        microphone: FakeMicrophone = FakeMicrophone(),
        selection: SelectionResult,
        pointer: CGPoint = .zero,
        createFolder: Bool = true,
        clipboardOn: Bool? = nil,
        freezeOn: Bool = false,
        codec: VideoCodec = .h264,
        systemAudio: Bool = false,
        recordMicrophone: Bool = false,
        copyToClipboard: (@MainActor (URL) throws -> Void)? = nil,
        onSaved: @escaping @MainActor (URL) -> Void = { _ in },
        onRecordingChange: @escaping @MainActor (CGRect?) -> Void = { _ in }
    ) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "GlintTests-\(UUID().uuidString)")
        folder = createFolder ? root : root.appending(path: "missing")
        if createFolder {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let settings = GlintSettings(store: MemoryStore(), defaultSaveFolder: folder)
        settings.copyToClipboardAfterCapture = clipboardOn ?? (copyToClipboard != nil)
        settings.freezeScreenWhileSelecting = freezeOn
        settings.recordingCodec = codec
        settings.recordSystemAudio = systemAudio
        settings.recordMicrophone = recordMicrophone
        self.settings = settings
        self.microphone = microphone
        selector = FakeSelector(selection)
        coordinator = CaptureCoordinator(
            capturer: capturer,
            recorder: recorder,
            microphone: microphone,
            selector: selector,
            alerts: alerts,
            settings: settings,
            now: { Date(timeIntervalSince1970: 1_795_000_000) },
            fileExists: { FileManager.default.fileExists(atPath: $0.path) },
            pointerLocation: { pointer },
            copyToClipboard: { url, _ in try copyToClipboard?(url) },
            onSaved: { url, _ in onSaved(url) },
            onRecordingChange: onRecordingChange
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
    #expect(name.hasPrefix("Glint ") && name.contains(" at ") && name.hasSuffix(".png"))
    #expect(harness.alerts.presented.isEmpty)
}

@MainActor @Test func savedCaptureIsHandedToThumbnail() async throws {
    var handed: [URL] = []
    let harness = try Harness(selection: .area(CGRect(x: 10, y: 10, width: 5, height: 5)), onSaved: { handed.append($0) })
    await harness.coordinator.run(.area)
    #expect(handed.map(\.lastPathComponent) == (try harness.savedFiles()))
}

@MainActor @Test func windowCapturesPickedWindow() async throws {
    let capturer = FakeCapturer()
    let harness = try Harness(capturer: capturer, selection: .window(42))
    await harness.coordinator.run(.window)
    #expect(await capturer.capturedWindowIDs == [42])
    #expect(try harness.savedFiles().count == 1)
    #expect(harness.alerts.presented.isEmpty)
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
    let controller = SelectionOverlayController(snapshot: { _ in throw CaptureError.emptySelection })
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
    #expect(alert.title != "Glint couldn't take the screenshot")
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

@MainActor @Test func recordingAnAreaStartsOnItsDisplayShowsTheBorderAndStopHandsOverTheMP4() async throws {
    let recorder = FakeRecorder()
    var regions: [CGRect?] = []
    var handed: [URL] = []
    let harness = try Harness(
        recorder: recorder,
        selection: .area(recordedArea),
        onSaved: { handed.append($0) },
        onRecordingChange: { regions.append($0) }
    )
    await harness.coordinator.toggleRecording(.area)
    let start = try #require(await recorder.starts.first)
    #expect(start.target == .area(recordedArea, on: mainDisplay))
    #expect(start.options == RecordingOptions(codec: .h264, systemAudio: false, microphone: false))
    #expect(start.url.deletingLastPathComponent().standardizedFileURL == harness.folder.standardizedFileURL)
    #expect(start.url.lastPathComponent.hasPrefix("Glint ") && start.url.pathExtension == "mp4")
    #expect(regions == [recordedArea])
    #expect(handed.isEmpty)

    await harness.coordinator.stopRecording()
    #expect(regions == [recordedArea, nil])
    #expect(handed == [start.url])
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

@MainActor @Test func recordingUsesTheCodecFromSettings() async throws {
    let recorder = FakeRecorder()
    let harness = try Harness(recorder: recorder, selection: .area(recordedArea), codec: .hevc)
    await harness.coordinator.toggleRecording(.area)
    #expect(await recorder.starts.first?.options.codec == .hevc)
    await harness.coordinator.stopRecording()
}

@MainActor @Test func recordingAWindowBordersItsFrameInAppKitCoordinates() async throws {
    let window = CapturableWindow(id: 42, frame: CGRect(x: 50, y: 100, width: 400, height: 300))
    let recorder = FakeRecorder()
    var regions: [CGRect?] = []
    let harness = try Harness(
        capturer: FakeCapturer(windows: [window]),
        recorder: recorder,
        selection: .window(42),
        onRecordingChange: { regions.append($0) }
    )
    await harness.coordinator.toggleRecording(.window)
    #expect(await recorder.starts.first?.target == .window(42))
    #expect(regions == [CGRect(x: 50, y: 982 - 400, width: 400, height: 300)])
    await harness.coordinator.stopRecording()
}

@MainActor @Test func cancellingTheRecordingSelectionStartsNothing() async throws {
    let recorder = FakeRecorder()
    var regions: [CGRect?] = []
    let harness = try Harness(recorder: recorder, selection: .cancelled, onRecordingChange: { regions.append($0) })
    await harness.coordinator.toggleRecording(.area)
    #expect(await recorder.starts.isEmpty)
    #expect(regions.isEmpty)
    #expect(harness.alerts.presented.isEmpty)
}

@MainActor @Test func recordingWithoutPermissionAlertsBeforeAnyOverlay() async throws {
    let recorder = FakeRecorder()
    let harness = try Harness(capturer: FakeCapturer(permissionGranted: false), recorder: recorder, selection: .area(recordedArea))
    await harness.coordinator.toggleRecording(.area)
    #expect(harness.selector.selectionCount == 0)
    #expect(await recorder.starts.isEmpty)
    let alert = try #require(harness.alerts.presented.first)
    #expect(alert.buttons.contains(.openSystemSettings))
}

@MainActor @Test func aRecordingThatFailsToStartSaysWhyAndShowsNoIndicator() async throws {
    let failure = CaptureError.recordingFailed(path: "/tmp/x.mp4", reason: "Start stream failed")
    var regions: [CGRect?] = []
    let harness = try Harness(recorder: FakeRecorder(startFailure: failure), selection: .area(recordedArea), onRecordingChange: { regions.append($0) })
    await harness.coordinator.toggleRecording(.area)
    let alert = try #require(harness.alerts.presented.first)
    #expect(alert.title == "Glint couldn't start the recording")
    #expect(alert.message == failure.localizedDescription)
    #expect(regions.isEmpty)
}

@MainActor @Test func aRecordingThatStopsOnItsOwnKeepsTheFileAndSaysWhy() async throws {
    let failure = CaptureError.recordingStoppedEarly(path: "/tmp/x.mp4", reason: "Failed to find any displays or windows to capture.")
    var handed: [URL] = []
    var regions: [CGRect?] = []
    let harness = try Harness(
        recorder: FakeRecorder(outcome: failure),
        selection: .area(recordedArea),
        onSaved: { handed.append($0) },
        onRecordingChange: { regions.append($0) }
    )
    await harness.coordinator.toggleRecording(.area)
    await harness.coordinator.stopRecording()
    #expect(handed.count == 1)
    #expect(regions.last == .some(nil))
    let alert = try #require(harness.alerts.presented.first)
    #expect(alert.title == "Glint's recording stopped early")
    #expect(alert.message.contains("Failed to find any displays or windows to capture."))
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

@MainActor @Test func microphoneOnWithoutPermissionAlertsBeforeAnyOverlayAndRecordsNothing() async throws {
    let recorder = FakeRecorder()
    let harness = try Harness(recorder: recorder, microphone: FakeMicrophone(.denied), selection: .area(recordedArea), recordMicrophone: true)
    await harness.coordinator.toggleRecording(.area)
    #expect(harness.selector.selectionCount == 0)
    #expect(await recorder.starts.isEmpty)
    let alert = try #require(harness.alerts.presented.first)
    #expect(alert.message == CoordinatorError.microphoneDeniedForRecording.localizedDescription)
    #expect(alert.message.contains("System Settings > Privacy & Security > Microphone"))
    #expect(alert.buttons == [.openMicrophoneSettings, .ok])
}

@MainActor @Test func turningTheMicrophoneOnWithPermissionNeverPrompts() async throws {
    let harness = try Harness(microphone: FakeMicrophone(.authorized), selection: .cancelled)
    await harness.coordinator.setRecordMicrophone(true)
    #expect(harness.settings.recordMicrophone)
    #expect(harness.microphone.requestCount == 0)
    #expect(harness.alerts.presented.isEmpty)
}

@MainActor @Test func turningTheMicrophoneOnAsksOnceAndKeepsItOnWhenGranted() async throws {
    let harness = try Harness(microphone: FakeMicrophone(.notDetermined, grants: true), selection: .cancelled)
    await harness.coordinator.setRecordMicrophone(true)
    #expect(harness.settings.recordMicrophone)
    #expect(harness.microphone.requestCount == 1)
    #expect(harness.alerts.presented.isEmpty)
}

@MainActor @Test(arguments: [MicrophoneStatus.notDetermined, .denied])
func aRefusedMicrophoneLeavesTheToggleOffAndSaysWhatToDo(status: MicrophoneStatus) async throws {
    let harness = try Harness(microphone: FakeMicrophone(status, grants: false), selection: .cancelled)
    await harness.coordinator.setRecordMicrophone(true)
    #expect(!harness.settings.recordMicrophone)
    #expect(harness.microphone.requestCount == (status == .notDetermined ? 1 : 0))
    let alert = try #require(harness.alerts.presented.first)
    #expect(alert.title == "Glint can't record the microphone")
    #expect(alert.message == CoordinatorError.microphoneDenied.localizedDescription)
    #expect(alert.buttons == [.openMicrophoneSettings, .ok])
}

@MainActor @Test func turningTheMicrophoneOffNeverPrompts() async throws {
    let harness = try Harness(microphone: FakeMicrophone(.notDetermined), selection: .cancelled, recordMicrophone: true)
    await harness.coordinator.setRecordMicrophone(false)
    #expect(!harness.settings.recordMicrophone)
    #expect(harness.microphone.requestCount == 0)
}

@MainActor @Test func theMicrophoneAlertButtonOpensTheMicrophonePane() async throws {
    let harness = try Harness(microphone: FakeMicrophone(.denied), selection: .cancelled)
    harness.alerts.answer = .openMicrophoneSettings
    await harness.coordinator.setRecordMicrophone(true)
    #expect(harness.microphone.settingsOpened == 1)
}
