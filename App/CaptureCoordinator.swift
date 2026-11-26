import AppKit
import LunettaCapture
import LunettaCore

enum CaptureMode {
    case area, window, fullScreen
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
    var status: MicrophoneStatus { get }
    var inputs: [AudioInput] { get }
    func requestAccess() async -> Bool
    func openSettings()
}

/// The pressed keys drawn over a recorded area, and the Input Monitoring access reading them needs.
@MainActor
protocol KeystrokeShowing {
    var isAllowed: Bool { get }
    /// Returns the overlay's window ID, which the recording keeps while it leaves out Lunetta's other windows.
    func show(over region: CGRect) throws -> UInt32
    func hide()
    func openSettings()
}

protocol ActiveRecording: Sendable {
    func stop() async
    func finished() async throws
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
        case openInputMonitoringSettings = "Open Input Monitoring Settings"

        init(_ fix: RecordingFix) {
            self = switch fix {
            case .allowMicrophone: .allowMicrophone
            case .openMicrophoneSettings: .openMicrophoneSettings
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

    init(target: RecordingTarget, options: RecordingOptions, input: AudioInput?, url: URL, status: RecordingStatus) {
        self.target = target
        self.options = options
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
    private let selector: any Selecting
    private let alerts: any AlertPresenting
    private let settings: LunettaSettings
    private let now: () -> Date
    private let fileExists: (URL) -> Bool
    private let pointerLocation: @MainActor () -> CGPoint
    private let copyToClipboard: @MainActor (URL, Data) throws -> Void
    private let writePNG: @Sendable (CGImage, URL) async throws -> Data
    private let playShutterSound: @MainActor () -> Void
    private let onSaved: @MainActor (URL, _ thumbnail: CGImage?) -> Void
    private let onRecordingEvent: @MainActor (RecordingEvent) -> Void
    private let countDown: @MainActor (RecordingStatus) async -> Bool
    private var isRunning = false
    private var delivery: Task<Void, Never>?
    private var session: RecordingSession?
    private var countdown: Task<Bool, Never>?

    init(
        capturer: any Capturing,
        recorder: any Recording,
        microphone: any MicrophoneAccess,
        keystrokes: any KeystrokeShowing,
        selector: any Selecting,
        alerts: any AlertPresenting,
        settings: LunettaSettings,
        now: @escaping () -> Date = Date.init,
        fileExists: @escaping (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
        pointerLocation: @escaping @MainActor () -> CGPoint = { NSEvent.mouseLocation },
        copyToClipboard: @escaping @MainActor (URL, Data) throws -> Void = { url, data in try NSPasteboard.general.copyPNGData(data, fileURL: url) },
        writePNG: @escaping @Sendable (CGImage, URL) async throws -> Data = CaptureCoordinator.writePNG,
        playShutterSound: @escaping @MainActor () -> Void = {},
        onSaved: @escaping @MainActor (URL, _ thumbnail: CGImage?) -> Void = { _, _ in },
        onRecordingEvent: @escaping @MainActor (RecordingEvent) -> Void = { _ in },
        countDown: @escaping @MainActor (RecordingStatus) async -> Bool = { _ in true }
    ) {
        self.capturer = capturer
        self.recorder = recorder
        self.microphone = microphone
        self.keystrokes = keystrokes
        self.selector = selector
        self.alerts = alerts
        self.settings = settings
        self.now = now
        self.fileExists = fileExists
        self.pointerLocation = pointerLocation
        self.copyToClipboard = copyToClipboard
        self.writePNG = writePNG
        self.playShutterSound = playShutterSound
        self.onSaved = onSaved
        self.onRecordingEvent = onRecordingEvent
        self.countDown = countDown
    }

    /// Only taking the image blocks the next capture (#99); deliveries queue so each one names its file after the ones before it are on disk.
    func run(_ mode: CaptureMode) async {
        guard let image = await captureImage(mode) else { return }
        let previous = delivery
        let delivering = Task {
            await previous?.value
            do {
                try await deliver(image)
            } catch {
                present(error)
            }
        }
        delivery = delivering
        await delivering.value
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

    /// The record hotkeys toggle: during the countdown they cancel it, while recording they stop. The panel's Record button
    /// comes here too, with the same checks, so both start from the same choices.
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
        var showsKeys = false
        defer { if showsKeys, session == nil { keystrokes.hide() } }
        do {
            guard await capturer.hasPermission() else { throw CaptureError.permissionDenied }
            if let problem = recordingProblems(for: mode).first { throw problem }
            let choices = settings.recordingChoices
            guard let (target, region) = try await selectRecordingTarget(mode) else { return }
            selected = true
            let input = choices.microphone ? choices.input : nil
            var options = RecordingOptions(
                codec: settings.recordingCodec,
                systemAudio: choices.systemAudio,
                microphone: choices.microphone,
                microphoneID: input?.id,
                showsClicks: choices.showsClicks
            )
            if choices.showsKeys {
                showsKeys = true
                options.keptWindowIDs = [try keystrokes.show(over: region)]
            }
            try await record(target, status: RecordingStatus(region: region, dimsOutside: mode == .area), options: options, input: input)
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
        let showsKeys = !session.options.keptWindowIDs.isEmpty
        defer { if showsKeys, self.session == nil { keystrokes.hide() } }
        do {
            var options = session.options
            // Discarding took the pressed keys down with the old recording; the new one gets them back.
            if showsKeys { options.keptWindowIDs = [try keystrokes.show(over: session.status.region)] }
            let status = RecordingStatus(region: session.status.region, dimsOutside: session.status.dimsOutside)
            try await record(session.target, status: status, options: options, input: session.input)
        } catch {
            onRecordingEvent(.ended(.failed))
            present(error, failure: "Lunetta couldn't start the recording over")
        }
    }

    private func record(_ target: RecordingTarget, status: RecordingStatus, options: RecordingOptions, input: AudioInput?) async throws {
        guard await countDownIfOn(status) else { return }
        let url = nextFileURL(ext: "mp4")
        let active = try await recorder.startRecording(target, to: url, options: options)
        var status = status
        status.clock.start(at: now())
        let session = RecordingSession(target: target, options: options, input: input, url: url, status: status)
        self.session = session
        attach(active, writingTo: url, in: session)
        onRecordingEvent(.started(status))
    }

    private func countDownIfOn(_ status: RecordingStatus) async -> Bool {
        guard settings.recordingCountdown else { return true }
        let counting = Task { await countDown(status) }
        countdown = counting
        defer { countdown = nil }
        return await counting.value
    }

    /// What keeps the panel's current choices from recording `mode`; the record hotkeys check the same list.
    func recordingProblems(for mode: RecordingMode) -> [RecordingProblem] {
        RecordingPreflight.problems(
            mode: mode,
            choices: settings.recordingChoices,
            microphone: microphone.status,
            inputMonitoringAllowed: keystrokes.isAllowed,
            connectedInputs: settings.recordMicrophone ? microphone.inputs : []
        )
    }

    func fix(_ fix: RecordingFix) async {
        switch fix {
        case .allowMicrophone: _ = await microphone.requestAccess()
        case .openMicrophoneSettings: microphone.openSettings()
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
        if !session.options.keptWindowIDs.isEmpty { keystrokes.hide() }
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
        if saved { onSaved(session.url, nil) }
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

    private func selectRecordingTarget(_ mode: RecordingMode) async throws -> (RecordingTarget, region: CGRect)? {
        switch mode {
        case .area:
            guard case .area(let selection) = try await selector.selectArea(frozen: []) else { return nil }
            guard let display = DisplayGeometry.display(forSelection: selection, in: await capturer.displays()) else {
                throw CaptureError.emptySelection
            }
            let region = selection.intersection(display.frame)
            return (.area(region, on: display), region)
        case .window:
            let windows = windowList()
            guard case .window(let id) = try await selector.selectWindow(windows) else {
                windows.cancel()
                return nil
            }
            guard let window = try await windows.value.first(where: { $0.id == id }) else { throw CaptureError.windowNotFound(id) }
            let mainDisplayHeight = await capturer.displays().first { $0.frame.origin == .zero }?.frame.height ?? 0
            return (.window(id), DisplayGeometry.appKitRect(fromTopLeftGlobal: window.frame, mainDisplayHeight: mainDisplayHeight))
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

    private func deliver(_ image: CGImage) async throws {
        let url = nextFileURL(ext: "png")
        let maxScale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        let maxThumbnailPixels = LunettaSettings.thumbnailWidthRange.upperBound * maxScale
        let writePNG = writePNG
        let (pngData, thumbnail) = try await Task.detached(priority: .userInitiated) {
            let data = try await writePNG(image, url)
            let thumb = ThumbnailDownsampler.downsample(image, maxPixelSize: maxThumbnailPixels)
            return (data, thumb)
        }.value
        onSaved(url, thumbnail)
        // Upload after capture copies the link once the bucket answers; copying the image first would only be overwritten.
        guard settings.copyToClipboardAfterCapture, !settings.uploadAfterCapture else { return }
        do {
            try copyToClipboard(url, pngData)
        } catch {
            throw CoordinatorError.clipboardFailed(savedTo: url, reason: error.localizedDescription)
        }
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
        }
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
        case .openInputMonitoringSettings:
            keystrokes.openSettings()
        }
    }
}
