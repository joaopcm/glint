import AppKit
import CoreGraphics

public enum CapturePermission {
    public static func isGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    public static func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    @MainActor
    public static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
}
