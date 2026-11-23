import Foundation

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

@MainActor
public final class GlintSettings {
    private enum Key {
        static let saveFolderPath = "saveFolderPath"
        static let copyToClipboardAfterCapture = "copyToClipboardAfterCapture"
        static let overlayCorner = "overlayCorner"
        static let overlayAutoDismiss = "overlayAutoDismiss"
        static let thumbnailWidth = "thumbnailWidth"
    }

    private let store: KeyValueStore
    private let defaultSaveFolder: URL

    public init(store: KeyValueStore, defaultSaveFolder: URL) {
        self.store = store
        self.defaultSaveFolder = defaultSaveFolder
    }

    public var saveFolder: URL {
        get {
            guard let path = store.string(forKey: Key.saveFolderPath), !path.isEmpty else {
                return defaultSaveFolder
            }
            return URL(filePath: path)
        }
        set { store.set(newValue.path, forKey: Key.saveFolderPath) }
    }

    public var copyToClipboardAfterCapture: Bool {
        get { store.bool(forKey: Key.copyToClipboardAfterCapture) ?? false }
        set { store.set(newValue, forKey: Key.copyToClipboardAfterCapture) }
    }

    public var overlayCorner: OverlayCorner {
        get { store.string(forKey: Key.overlayCorner).flatMap(OverlayCorner.init(rawValue:)) ?? .bottomRight }
        set { store.set(newValue.rawValue, forKey: Key.overlayCorner) }
    }

    public static let defaultThumbnailWidth: Double = 240
    /// 160: narrowest card whose hover toolbar (4 × 28 pt buttons + insets = 130 pt) still fits with margins.
    /// 480: a 320 pt tall card; two still fit in the column on a 13" MacBook Air (≈ 900 pt visible height).
    public static let thumbnailWidthRange: ClosedRange<Double> = 160...480

    /// Width of the quick-access thumbnails in points (height follows at 3:2), clamped to `thumbnailWidthRange`.
    public var thumbnailWidth: Double {
        get { Self.clampWidth(store.double(forKey: Key.thumbnailWidth) ?? Self.defaultThumbnailWidth) }
        set { store.set(Self.clampWidth(newValue), forKey: Key.thumbnailWidth) }
    }

    public static func clampWidth(_ width: Double) -> Double {
        guard width.isFinite else { return defaultThumbnailWidth }
        return min(max(width, thumbnailWidthRange.lowerBound), thumbnailWidthRange.upperBound)
    }

    /// Off by default: thumbnails stay until dismissed, like CleanShot.
    public var overlayAutoDismiss: Bool {
        get { store.bool(forKey: Key.overlayAutoDismiss) ?? false }
        set { store.set(newValue, forKey: Key.overlayAutoDismiss) }
    }
}
