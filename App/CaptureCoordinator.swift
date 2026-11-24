import AppKit
import GlintCapture
import GlintCore

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
    func captureDisplay(id: UInt32) async throws -> CGImage
    func captureWindow(id: UInt32) async throws -> CGImage
    func shareableWindows() async throws -> [CapturableWindow]
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

    var errorDescription: String? {
        switch self {
        case .noDisplays:
            "No display is connected, so there is nothing to capture."
        case .clipboardFailed(let url, let reason):
            "The screenshot was saved to \(url.path), but copying it to the clipboard failed: \(reason)"
        }
    }
}

@MainActor
final class CaptureCoordinator {
    private let capturer: any Capturing
    private let selector: any Selecting
    private let alerts: any AlertPresenting
    private let settings: GlintSettings
    private let now: () -> Date
    private let fileExists: (URL) -> Bool
    private let pointerLocation: @MainActor () -> CGPoint
    private let copyToClipboard: @MainActor (URL) throws -> Void
    private let onSaved: @MainActor (URL) -> Void
    private var isRunning = false

    init(
        capturer: any Capturing,
        selector: any Selecting,
        alerts: any AlertPresenting,
        settings: GlintSettings,
        now: @escaping () -> Date = Date.init,
        fileExists: @escaping (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
        pointerLocation: @escaping @MainActor () -> CGPoint = { NSEvent.mouseLocation },
        copyToClipboard: @escaping @MainActor (URL) throws -> Void = { try NSPasteboard.general.copyPNGFile(at: $0) },
        onSaved: @escaping @MainActor (URL) -> Void = { _ in }
    ) {
        self.capturer = capturer
        self.selector = selector
        self.alerts = alerts
        self.settings = settings
        self.now = now
        self.fileExists = fileExists
        self.pointerLocation = pointerLocation
        self.copyToClipboard = copyToClipboard
        self.onSaved = onSaved
    }

    func run(_ mode: CaptureMode) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        guard let image = await takeImage(mode) else { return }
        do {
            try deliver(image)
        } catch {
            present(error)
        }
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

    private func deliver(_ image: CGImage) throws {
        let url = CaptureNaming.uniqueFileURL(
            in: settings.saveFolder,
            baseName: CaptureNaming.baseName(for: now(), timeZone: .current),
            ext: "png",
            exists: fileExists
        )
        try PNGWriter.write(image, to: url)
        onSaved(url)
        guard settings.copyToClipboardAfterCapture else { return }
        do {
            try copyToClipboard(url)
        } catch {
            throw CoordinatorError.clipboardFailed(savedTo: url, reason: error.localizedDescription)
        }
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
            let windows = Task { try await capturer.shareableWindows() }
            guard case .window(let id) = try await selector.selectWindow(windows) else { return nil }
            return try await capturer.captureWindow(id: id)
        case .fullScreen:
            let displays = await capturer.displays()
            guard let display = DisplayGeometry.display(nearest: pointerLocation(), in: displays) else {
                throw CoordinatorError.noDisplays
            }
            return try await capturer.captureDisplay(id: display.id)
        }
    }

    private func freezeDisplays() async throws -> [FrozenDisplay] {
        let displays = await capturer.displays()
        guard !displays.isEmpty else { throw CoordinatorError.noDisplays }
        let capturer = capturer
        return try await withThrowingTaskGroup(of: FrozenDisplay.self) { group in
            for display in displays {
                group.addTask { FrozenDisplay(display: display, image: try await capturer.captureDisplay(id: display.id)) }
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

    private func present(_ error: any Error) {
        let needsPermission = (error as? CaptureError) == .permissionDenied
        let savedButNotCopied = if case .clipboardFailed = error as? CoordinatorError { true } else { false }
        let alert = CaptureAlert(
            title: savedButNotCopied ? "Glint saved the screenshot but couldn't copy it" : "Glint couldn't take the screenshot",
            message: error.localizedDescription,
            buttons: needsPermission ? [.openSystemSettings, .ok] : [.ok]
        )
        guard alerts.present(alert) == .openSystemSettings else { return }
        // CGPreflightScreenCaptureAccess never registers Glint with TCC; without this request
        // Glint is missing from the Screen Recording list and the user has to add it by hand.
        _ = CapturePermission.request()
        CapturePermission.openSettings()
    }
}
