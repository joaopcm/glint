import AppKit

/// The windows that frame a capture rather than belong in it: the selection overlay, the recording stage and the
/// recording HUD. ScreenCapturer leaves these out and captures every other Lunetta window like any app's.
@MainActor
enum CaptureChrome {
    private static let windows = NSHashTable<NSWindow>.weakObjects()

    static func mark(_ window: NSWindow) {
        windows.add(window)
    }

    static func windowIDs() -> [UInt32] {
        windows.allObjects.compactMap { UInt32(exactly: $0.windowNumber) }
    }
}
