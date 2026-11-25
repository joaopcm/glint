import AppKit
import AVFoundation
import LunettaCapture
import LunettaCore

extension ScreenCapturer: Capturing {
    @MainActor
    func hasPermission() async -> Bool {
        CapturePermission.isGranted()
    }

    @MainActor
    func displays() async -> [DisplayInfo] {
        DisplayInfo.onScreens()
    }
}

extension ScreenCapturer: Recording {
    func startRecording(_ target: RecordingTarget, to url: URL, options: RecordingOptions) async throws -> any ActiveRecording {
        try await record(target, to: url, options: options)
    }
}

@MainActor
struct SystemMicrophoneAccess: MicrophoneAccess {
    var status: MicrophoneStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .authorized
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }
}

extension ScreenRecording: ActiveRecording {}

@MainActor
struct NSAlertPresenter: AlertPresenting {
    func present(_ alert: CaptureAlert) -> CaptureAlert.Button {
        let panel = NSAlert()
        panel.alertStyle = .warning
        panel.messageText = alert.title
        panel.informativeText = alert.message
        for button in alert.buttons {
            panel.addButton(withTitle: button.rawValue)
        }
        let index = runWithLunettaActive { panel.runModal() }.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return alert.buttons.indices.contains(index) ? alert.buttons[index] : .ok
    }
}

/// Modal UI needs Lunetta active; hand focus back to the app the user was in afterwards.
@MainActor
func runWithLunettaActive<T>(_ body: () -> T) -> T {
    let previousApp = NSWorkspace.shared.frontmostApplication
    NSApp.activate()
    defer {
        if let previousApp, previousApp != NSRunningApplication.current {
            NSApp.yieldActivation(to: previousApp)
            previousApp.activate()
        }
    }
    return body()
}

enum PasteboardError: LocalizedError {
    case rejected

    var errorDescription: String? {
        switch self {
        case .rejected: "The system pasteboard did not accept the capture."
        }
    }
}

extension NSPasteboard {
    func copyPNGFile(at url: URL) throws {
        try copyPNGData(Data(contentsOf: url), fileURL: url)
    }

    func copyPNGData(_ data: Data, fileURL url: URL) throws {
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        item.setData(data, forType: .png)
        clearContents()
        guard writeObjects([item]) else { throw PasteboardError.rejected }
    }

    func copyFileReference(_ url: URL) throws {
        clearContents()
        guard writeObjects([url as NSURL]) else { throw PasteboardError.rejected }
    }

    func copyText(_ text: String) throws {
        clearContents()
        guard setString(text, forType: .string) else { throw PasteboardError.rejected }
    }
}
