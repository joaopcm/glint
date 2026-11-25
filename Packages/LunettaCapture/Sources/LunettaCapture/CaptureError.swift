import Foundation

public enum CaptureError: Error, LocalizedError, Equatable {
    case permissionDenied
    case emptySelection
    case displayNotFound(UInt32)
    case windowNotFound(UInt32)
    case writeFailed(path: String, underlying: String)
    case textRecognitionFailed(String)
    case recordingFailed(path: String, reason: String)
    case recordingStoppedEarly(path: String, reason: String)
    case wallpaperUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Lunetta needs Screen Recording permission. Turn on Lunetta in System Settings > Privacy & Security > Screen & System Audio Recording, then quit and reopen Lunetta."
        case .emptySelection:
            "The selected area is empty or outside every display."
        case .displayNotFound(let id):
            "Display \(id) is not available to capture. It may have been disconnected."
        case .windowNotFound(let id):
            "Window \(id) is not available to capture. It may have closed or left the screen."
        case .writeFailed(let path, let underlying):
            "Could not save the screenshot to \(path): \(underlying)"
        case .textRecognitionFailed(let reason):
            "Could not read the text in the selection: \(reason)"
        case .recordingFailed(let path, let reason):
            "Could not record to \(path): \(reason)"
        case .recordingStoppedEarly(let path, let reason):
            "The recording stopped on its own: \(reason) What was recorded until then is saved to \(path)."
        case .wallpaperUnavailable(let reason):
            "Could not put the window on your wallpaper: \(reason). Turn off \"Wallpaper behind window captures\" in Lunetta Settings > General to capture the window on its own."
        }
    }
}
