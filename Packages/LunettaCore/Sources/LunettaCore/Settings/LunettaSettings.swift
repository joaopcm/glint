import Foundation
import Observation

public protocol KeyValueStore: AnyObject {
    func string(forKey key: String) -> String?
    func set(_ value: String?, forKey key: String)
    func bool(forKey key: String) -> Bool?
    func set(_ value: Bool, forKey key: String)
    func double(forKey key: String) -> Double?
    func set(_ value: Double, forKey key: String)
}

public enum OverlayCorner: String, CaseIterable, Sendable {
    case bottomLeft, bottomRight
}

public enum VideoCodec: String, CaseIterable, Sendable {
    case h264, hevc
}

@MainActor @Observable
public final class LunettaSettings {
    private enum Key {
        static let saveFolderPath = "saveFolderPath"
        static let copyToClipboardAfterCapture = "copyToClipboardAfterCapture"
        static let overlayCorner = "overlayCorner"
        static let overlayAutoDismiss = "overlayAutoDismiss"
        static let thumbnailWidth = "thumbnailWidth"
        static let freezeScreenWhileSelecting = "freezeScreenWhileSelecting"
        static let showMagnifierWhileSelecting = "showMagnifierWhileSelecting"
        static let windowCaptureWallpaper = "windowCaptureWallpaper"
        static let windowWallpaperPadding = "windowWallpaperPadding"
        static let recordingCodec = "recordingCodec"
        static let recordSystemAudio = "recordSystemAudio"
        static let recordMicrophone = "recordMicrophone"
        static let bucketEndpoint = "bucketEndpoint"
        static let bucketRegion = "bucketRegion"
        static let bucketName = "bucketName"
        static let bucketPathStyle = "bucketPathStyle"
        static let bucketKeyPrefix = "bucketKeyPrefix"
        static let bucketPublicBaseURL = "bucketPublicBaseURL"
        static let uploadAfterCapture = "uploadAfterCapture"
        static let pickerPromptExplained = "pickerPromptExplained"
    }

    private let store: KeyValueStore
    private let defaultSaveFolder: URL

    public init(store: KeyValueStore, defaultSaveFolder: URL) {
        self.store = store
        self.defaultSaveFolder = defaultSaveFolder
    }

    public var saveFolder: URL {
        get {
            access(keyPath: \.saveFolder)
            guard let path = store.string(forKey: Key.saveFolderPath), !path.isEmpty else {
                return defaultSaveFolder
            }
            return URL(filePath: path)
        }
        set { withMutation(keyPath: \.saveFolder) { store.set(newValue.path, forKey: Key.saveFolderPath) } }
    }

    public var copyToClipboardAfterCapture: Bool {
        get {
            access(keyPath: \.copyToClipboardAfterCapture)
            return store.bool(forKey: Key.copyToClipboardAfterCapture) ?? false
        }
        set { withMutation(keyPath: \.copyToClipboardAfterCapture) { store.set(newValue, forKey: Key.copyToClipboardAfterCapture) } }
    }

    public var overlayCorner: OverlayCorner {
        get {
            access(keyPath: \.overlayCorner)
            return store.string(forKey: Key.overlayCorner).flatMap(OverlayCorner.init(rawValue:)) ?? .bottomRight
        }
        set { withMutation(keyPath: \.overlayCorner) { store.set(newValue.rawValue, forKey: Key.overlayCorner) } }
    }

    public static let defaultThumbnailWidth: Double = 240
    /// 190: narrowest card whose hover toolbar (5 × 28 pt buttons + 4 × 2 pt spacing + 12 pt insets = 160 pt) still fits
    /// inside the 5 pt rim with 10 pt to spare on each side.
    /// 480: a 320 pt tall card; two still fit in the column on a 13" MacBook Air (≈ 900 pt visible height).
    public static let thumbnailWidthRange: ClosedRange<Double> = 190...480

    /// Width of the quick-access thumbnails in points (height follows at 3:2), clamped to `thumbnailWidthRange`.
    public var thumbnailWidth: Double {
        get {
            access(keyPath: \.thumbnailWidth)
            return Self.clampWidth(store.double(forKey: Key.thumbnailWidth) ?? Self.defaultThumbnailWidth)
        }
        set { withMutation(keyPath: \.thumbnailWidth) { store.set(Self.clampWidth(newValue), forKey: Key.thumbnailWidth) } }
    }

    public static func clampWidth(_ width: Double) -> Double {
        guard width.isFinite else { return defaultThumbnailWidth }
        return min(max(width, thumbnailWidthRange.lowerBound), thumbnailWidthRange.upperBound)
    }

    /// Off by default: thumbnails stay until dismissed, like CleanShot.
    public var overlayAutoDismiss: Bool {
        get {
            access(keyPath: \.overlayAutoDismiss)
            return store.bool(forKey: Key.overlayAutoDismiss) ?? false
        }
        set { withMutation(keyPath: \.overlayAutoDismiss) { store.set(newValue, forKey: Key.overlayAutoDismiss) } }
    }

    /// Off by default: freezing grabs every display before the overlay shows, which delays the crosshair.
    public var freezeScreenWhileSelecting: Bool {
        get {
            access(keyPath: \.freezeScreenWhileSelecting)
            return store.bool(forKey: Key.freezeScreenWhileSelecting) ?? false
        }
        set { withMutation(keyPath: \.freezeScreenWhileSelecting) { store.set(newValue, forKey: Key.freezeScreenWhileSelecting) } }
    }

    /// Off by default: the crosshair alone stays out of the way, and no display grab runs to feed the loupe.
    public var showMagnifierWhileSelecting: Bool {
        get {
            access(keyPath: \.showMagnifierWhileSelecting)
            return store.bool(forKey: Key.showMagnifierWhileSelecting) ?? false
        }
        set { withMutation(keyPath: \.showMagnifierWhileSelecting) { store.set(newValue, forKey: Key.showMagnifierWhileSelecting) } }
    }

    /// Off by default: the window and its shadow on transparency paste cleanly onto any background.
    public var windowCaptureWallpaper: Bool {
        get {
            access(keyPath: \.windowCaptureWallpaper)
            return store.bool(forKey: Key.windowCaptureWallpaper) ?? false
        }
        set { withMutation(keyPath: \.windowCaptureWallpaper) { store.set(newValue, forKey: Key.windowCaptureWallpaper) } }
    }

    public static let defaultWindowWallpaperPadding: Double = 64
    /// 256: a 1000 × 600 pt window with 256 pt on each side is 1512 × 1112 pt, taller than a 13" MacBook Air's
    /// 1512 × 982 pt screen, so past this the wallpaper stretches for everyday windows.
    public static let windowWallpaperPaddingRange: ClosedRange<Double> = 0...256

    /// Wallpaper shown around a window capture on each side, in points, clamped to `windowWallpaperPaddingRange`.
    public var windowWallpaperPadding: Double {
        get {
            access(keyPath: \.windowWallpaperPadding)
            return Self.clampPadding(store.double(forKey: Key.windowWallpaperPadding) ?? Self.defaultWindowWallpaperPadding)
        }
        set { withMutation(keyPath: \.windowWallpaperPadding) { store.set(Self.clampPadding(newValue), forKey: Key.windowWallpaperPadding) } }
    }

    /// `nil` when window captures leave the wallpaper out.
    public var wallpaperPaddingForWindowCaptures: Double? {
        windowCaptureWallpaper ? windowWallpaperPadding : nil
    }

    public static func clampPadding(_ padding: Double) -> Double {
        guard padding.isFinite else { return defaultWindowWallpaperPadding }
        return min(max(padding, windowWallpaperPaddingRange.lowerBound), windowWallpaperPaddingRange.upperBound)
    }

    /// H.264 by default: it plays everywhere, HEVC does not.
    public var recordingCodec: VideoCodec {
        get {
            access(keyPath: \.recordingCodec)
            return store.string(forKey: Key.recordingCodec).flatMap(VideoCodec.init(rawValue:)) ?? .h264
        }
        set { withMutation(keyPath: \.recordingCodec) { store.set(newValue.rawValue, forKey: Key.recordingCodec) } }
    }

    /// Off by default: a recording only picks up sound when the user asks for it (#18).
    public var recordSystemAudio: Bool {
        get {
            access(keyPath: \.recordSystemAudio)
            return store.bool(forKey: Key.recordSystemAudio) ?? false
        }
        set { withMutation(keyPath: \.recordSystemAudio) { store.set(newValue, forKey: Key.recordSystemAudio) } }
    }

    public var recordMicrophone: Bool {
        get {
            access(keyPath: \.recordMicrophone)
            return store.bool(forKey: Key.recordMicrophone) ?? false
        }
        set { withMutation(keyPath: \.recordMicrophone) { store.set(newValue, forKey: Key.recordMicrophone) } }
    }

    public var bucketEndpoint: String {
        get {
            access(keyPath: \.bucketEndpoint)
            return store.string(forKey: Key.bucketEndpoint) ?? ""
        }
        set { withMutation(keyPath: \.bucketEndpoint) { store.set(newValue, forKey: Key.bucketEndpoint) } }
    }

    public var bucketRegion: String {
        get {
            access(keyPath: \.bucketRegion)
            return store.string(forKey: Key.bucketRegion) ?? ""
        }
        set { withMutation(keyPath: \.bucketRegion) { store.set(newValue, forKey: Key.bucketRegion) } }
    }

    public var bucketName: String {
        get {
            access(keyPath: \.bucketName)
            return store.string(forKey: Key.bucketName) ?? ""
        }
        set { withMutation(keyPath: \.bucketName) { store.set(newValue, forKey: Key.bucketName) } }
    }

    public var bucketPathStyle: Bool {
        get {
            access(keyPath: \.bucketPathStyle)
            return store.bool(forKey: Key.bucketPathStyle) ?? false
        }
        set { withMutation(keyPath: \.bucketPathStyle) { store.set(newValue, forKey: Key.bucketPathStyle) } }
    }

    public var bucketKeyPrefix: String {
        get {
            access(keyPath: \.bucketKeyPrefix)
            return store.string(forKey: Key.bucketKeyPrefix) ?? ""
        }
        set { withMutation(keyPath: \.bucketKeyPrefix) { store.set(newValue, forKey: Key.bucketKeyPrefix) } }
    }

    public var bucketPublicBaseURL: String {
        get {
            access(keyPath: \.bucketPublicBaseURL)
            return store.string(forKey: Key.bucketPublicBaseURL) ?? ""
        }
        set { withMutation(keyPath: \.bucketPublicBaseURL) { store.set(newValue, forKey: Key.bucketPublicBaseURL) } }
    }

    /// Off by default: uploading sends the capture off this Mac, so the user asks for it.
    public var uploadAfterCapture: Bool {
        get {
            access(keyPath: \.uploadAfterCapture)
            return store.bool(forKey: Key.uploadAfterCapture) ?? false
        }
        set { withMutation(keyPath: \.uploadAfterCapture) { store.set(newValue, forKey: Key.uploadAfterCapture) } }
    }

    public var pickerPromptExplained: Bool {
        get {
            access(keyPath: \.pickerPromptExplained)
            return store.bool(forKey: Key.pickerPromptExplained) ?? false
        }
        set { withMutation(keyPath: \.pickerPromptExplained) { store.set(newValue, forKey: Key.pickerPromptExplained) } }
    }
}
