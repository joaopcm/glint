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

@MainActor @Observable
public final class GlintSettings {
    private enum Key {
        static let saveFolderPath = "saveFolderPath"
        static let copyToClipboardAfterCapture = "copyToClipboardAfterCapture"
        static let overlayCorner = "overlayCorner"
        static let overlayAutoDismiss = "overlayAutoDismiss"
        static let thumbnailWidth = "thumbnailWidth"
        static let freezeScreenWhileSelecting = "freezeScreenWhileSelecting"
        static let bucketEndpoint = "bucketEndpoint"
        static let bucketRegion = "bucketRegion"
        static let bucketName = "bucketName"
        static let bucketPathStyle = "bucketPathStyle"
        static let bucketKeyPrefix = "bucketKeyPrefix"
        static let bucketPublicBaseURL = "bucketPublicBaseURL"
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
    /// 160: narrowest card whose hover toolbar (4 × 28 pt buttons + insets = 130 pt) still fits with margins.
    /// 480: a 320 pt tall card; two still fit in the column on a 13" MacBook Air (≈ 900 pt visible height).
    public static let thumbnailWidthRange: ClosedRange<Double> = 160...480

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
}
