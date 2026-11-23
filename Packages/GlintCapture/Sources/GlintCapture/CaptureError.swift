import Foundation

public enum CaptureError: Error, LocalizedError, Equatable {
    case permissionDenied
    case emptySelection
    case displayNotFound(UInt32)
    case windowNotFound(UInt32)
    case writeFailed(path: String, underlying: String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Glint needs Screen Recording permission. Turn on Glint in System Settings > Privacy & Security > Screen & System Audio Recording, then quit and reopen Glint."
        case .emptySelection:
            "The selected area is empty or outside every display."
        case .displayNotFound(let id):
            "Display \(id) is not available to capture. It may have been disconnected."
        case .windowNotFound(let id):
            "Window \(id) is not available to capture. It may have closed or left the screen."
        case .writeFailed(let path, let underlying):
            "Could not save the screenshot to \(path): \(underlying)"
        }
    }
}
