import AppKit
import GlintCapture
import GlintCore

enum CaptureMode {
    case area, window, fullScreen
}

enum RecordingMode {
    case area, window
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
    func captureWindow(id: UInt32) async throws -> CGImage
    func shareableWindows() async throws -> [CapturableWindow]
}

protocol Recording: Sendable {
    func startRecording(_ target: RecordingTarget, to url: URL, options: RecordingOptions) async throws -> any ActiveRecording
}

enum MicrophoneStatus {
    case notDetermined, authorized, denied
}

@MainActor
protocol MicrophoneAccess {
    var status: MicrophoneStatus { get }
    func requestAccess() async -> Bool
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
        case openMicrophoneSettings = "Open Microphone Settings"
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
    case microphoneDenied
    case microphoneDeniedForRecording

    var errorDescription: String? {
        switch self {
        case .noDisplays:
            "No display is connected, so there is nothing to capture."
        case .clipboardFailed(let url, let reason):
            "The screenshot was saved to \(url.path), but copying it to the clipboard failed: \(reason)"
        case .microphoneDenied:
            "Glint isn't allowed to use the microphone. Turn on Glint in System Settings > Privacy & Security > Microphone, then turn on Record Microphone again."
        case .microphoneDeniedForRecording:
            "Record Microphone is on, but Glint isn't allowed to use the microphone. Turn on Glint in System Settings > Privacy & Security > Microphone, or turn off Record Microphone in the Glint menu."
        }
    }
}

@MainActor
final class CaptureCoordinator {
    private let capturer: any Capturing
    private let recorder: any Recording
    private let microphone: any MicrophoneAccess
    private let selector: any Selecting
    private let alerts: any AlertPresenting
    private let settings: GlintSettings
    private let now: () -> Date
    private let fileExists: (URL) -> Bool
    private let pointerLocation: @MainActor () -> CGPoint
    private let copyToClipboard: @MainActor (URL, Data) throws -> Void
    private let writePNG: @Sendable (CGImage, URL) async throws -> Data
    private let onSaved: @MainActor (URL, _ thumbnail: CGImage?) -> Void
    private let onRecordingChange: @MainActor (_ region: CGRect?) -> Void
    private var isRunning = false
    private var delivery: Task<Void, Never>?
    private var recording: (any ActiveRecording)?
    private var recordingEnd: Task<Void, Never>?

    init(
        capturer: any Capturing,
        recorder: any Recording,
        microphone: any MicrophoneAccess,
        selector: any Selecting,
        alerts: any AlertPresenting,
        settings: GlintSettings,
        now: @escaping () -> Date = Date.init,
        fileExists: @escaping (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
        pointerLocation: @escaping @MainActor () -> CGPoint = { NSEvent.mouseLocation },
        copyToClipboard: @escaping @MainActor (URL, Data) throws -> Void = { url, data in try NSPasteboard.general.copyPNGData(data, fileURL: url) },
        writePNG: @escaping @Sendable (CGImage, URL) async throws -> Data = CaptureCoordinator.writePNG,
        onSaved: @escaping @MainActor (URL, _ thumbnail: CGImage?) -> Void = { _, _ in },
        onRecordingChange: @escaping @MainActor (_ region: CGRect?) -> Void = { _ in }
    ) {
        self.capturer = capturer
        self.recorder = recorder
        self.microphone = microphone
        self.selector = selector
        self.alerts = alerts
        self.settings = settings
        self.now = now
        self.fileExists = fileExists
        self.pointerLocation = pointerLocation
        self.copyToClipboard = copyToClipboard
        self.writePNG = writePNG
        self.onSaved = onSaved
        self.onRecordingChange = onRecordingChange
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
        return await takeImage(mode)
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

    /// The record hotkeys and the menu items toggle: while a recording runs, they stop it.
    func toggleRecording(_ mode: RecordingMode) async {
        guard recording == nil else { return await stopRecording() }
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        do {
            guard await capturer.hasPermission() else { throw CaptureError.permissionDenied }
            if settings.recordMicrophone, microphone.status != .authorized { throw CoordinatorError.microphoneDeniedForRecording }
            guard let (target, region) = try await selectRecordingTarget(mode) else { return }
            let url = nextFileURL(ext: "mp4")
            let options = RecordingOptions(
                codec: settings.recordingCodec,
                systemAudio: settings.recordSystemAudio,
                microphone: settings.recordMicrophone
            )
            let active = try await recorder.startRecording(target, to: url, options: options)
            recording = active
            onRecordingChange(region)
            recordingEnd = Task { await self.awaitRecordingEnd(active, at: url) }
        } catch {
            present(error, failure: "Glint couldn't start the recording")
        }
    }

    /// The permission prompt only comes up when the toggle turns on; a refusal leaves the toggle off and says how to fix it.
    func setRecordMicrophone(_ on: Bool) async {
        guard on else {
            settings.recordMicrophone = false
            return
        }
        let allowed = switch microphone.status {
        case .authorized: true
        case .notDetermined: await microphone.requestAccess()
        case .denied: false
        }
        settings.recordMicrophone = allowed
        if !allowed { present(CoordinatorError.microphoneDenied, failure: "Glint can't record the microphone") }
    }

    func stopRecording() async {
        guard let recording, let recordingEnd else { return }
        await recording.stop()
        await recordingEnd.value
    }

    private func awaitRecordingEnd(_ active: any ActiveRecording, at url: URL) async {
        var failure: (any Error)?
        do {
            try await active.finished()
        } catch {
            failure = error
        }
        recording = nil
        recordingEnd = nil
        onRecordingChange(nil)
        if fileExists(url) { onSaved(url, nil) }
        guard let failure else { return }
        let stoppedEarly = if case .recordingStoppedEarly = failure as? CaptureError { true } else { false }
        present(failure, failure: stoppedEarly ? "Glint's recording stopped early" : "Glint couldn't finish the recording")
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
        let maxThumbnailPixels = GlintSettings.thumbnailWidthRange.upperBound * maxScale
        let writePNG = writePNG
        let (pngData, thumbnail) = try await Task.detached(priority: .userInitiated) {
            let data = try await writePNG(image, url)
            let thumb = ThumbnailDownsampler.downsample(image, maxPixelSize: maxThumbnailPixels)
            return (data, thumb)
        }.value
        onSaved(url, thumbnail)
        guard settings.copyToClipboardAfterCapture else { return }
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
            return try await capturer.captureWindow(id: id)
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

    private func present(_ error: any Error, failure: String = "Glint couldn't take the screenshot") {
        let needsPermission = (error as? CaptureError) == .permissionDenied
        let needsMicrophone = switch error as? CoordinatorError {
        case .microphoneDenied, .microphoneDeniedForRecording: true
        default: false
        }
        let savedButNotCopied = if case .clipboardFailed = error as? CoordinatorError { true } else { false }
        let alert = CaptureAlert(
            title: savedButNotCopied ? "Glint saved the screenshot but couldn't copy it" : failure,
            message: error.localizedDescription,
            buttons: needsPermission ? [.openSystemSettings, .ok] : needsMicrophone ? [.openMicrophoneSettings, .ok] : [.ok]
        )
        let choice = alerts.present(alert)
        if choice == .openMicrophoneSettings { microphone.openSettings() }
        guard choice == .openSystemSettings else { return }
        // CGPreflightScreenCaptureAccess never registers Glint with TCC; without this request
        // Glint is missing from the Screen Recording list and the user has to add it by hand.
        _ = CapturePermission.request()
        CapturePermission.openSettings()
    }
}
