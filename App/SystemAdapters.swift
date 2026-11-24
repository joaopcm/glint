import AppKit
import GlintCapture
import GlintCore

extension ScreenCapturer: Capturing {
    func hasPermission() async -> Bool {
        CapturePermission.isGranted()
    }

    func displays() async -> [DisplayInfo] {
        await MainActor.run { DisplayInfo.onScreens() }
    }
}

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
        let previousApp = NSWorkspace.shared.frontmostApplication
        NSApp.activate()
        let index = panel.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        if let previousApp, previousApp != NSRunningApplication.current {
            NSApp.yieldActivation(to: previousApp)
            previousApp.activate()
        }
        return alert.buttons.indices.contains(index) ? alert.buttons[index] : .ok
    }
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
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        item.setData(try Data(contentsOf: url), forType: .png)
        clearContents()
        guard writeObjects([item]) else { throw PasteboardError.rejected }
    }

    func copyText(_ text: String) throws {
        clearContents()
        guard setString(text, forType: .string) else { throw PasteboardError.rejected }
    }
}
