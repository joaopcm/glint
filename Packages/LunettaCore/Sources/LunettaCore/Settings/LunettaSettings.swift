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

public enum VideoCodec: String, CaseIterable, Codable, Sendable {
    case h264, hevc
}

public enum RecordingFrameRate: Int, CaseIterable, Codable, Sendable {
    case thirty = 30, sixty = 60
}

@MainActor @Observable
public final class LunettaSettings {
    private enum Key {
        static let saveFolderPath = "saveFolderPath"
        static let copyToClipboardAfterCapture = "copyToClipboardAfterCapture"
        static let playSoundOnCapture = "playSoundOnCapture"
        static let overlayCorner = "overlayCorner"
        static let overlayAutoDismiss = "overlayAutoDismiss"
        static let thumbnailWidth = "thumbnailWidth"
        static let freezeScreenWhileSelecting = "freezeScreenWhileSelecting"
        static let showMagnifierWhileSelecting = "showMagnifierWhileSelecting"
        static let windowCaptureWallpaper = "windowCaptureWallpaper"
        static let windowWallpaperPadding = "windowWallpaperPadding"
        static let recordingCodec = "recordingCodec"
        static let recordingFrameRate = "recordingFrameRate"
        static let recordSystemAudio = "recordSystemAudio"
        static let recordMicrophone = "recordMicrophone"
        static let recordingInputID = "recordingInputID"
        static let recordingInputName = "recordingInputName"
        static let recordCamera = "recordCamera"
        static let recordingCameraID = "recordingCameraID"
        static let recordingCameraName = "recordingCameraName"
        static let cameraBubbleDiameter = "cameraBubbleDiameter"
        static let showPressedKeys = "showPressedKeys"
        static let showMouseClicks = "showMouseClicks"
        static let recordingCountdown = "recordingCountdown"
        static let recordingSounds = "recordingSounds"
        static let recordsRaw = "recordsRaw"
        static let capsRenderToUHD = "capsRenderToUHD"
        static let bucketEndpoint = "bucketEndpoint"
        static let bucketRegion = "bucketRegion"
        static let bucketName = "bucketName"
        static let bucketPathStyle = "bucketPathStyle"
        static let bucketKeyPrefix = "bucketKeyPrefix"
        static let bucketPublicBaseURL = "bucketPublicBaseURL"
        static let uploadAfterCapture = "uploadAfterCapture"
        static let compressAfterCapture = "compressAfterCapture"
        static let compressCopiedMedia = "compressCopiedMedia"
        static let pickerPromptExplained = "pickerPromptExplained"
        static let annotationColor = "annotationColor"
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

    /// On by default: the shutter confirms the screenshot was taken, like macOS's own screenshots and CleanShot.
    public var playSoundOnCapture: Bool {
        get {
            access(keyPath: \.playSoundOnCapture)
            return store.bool(forKey: Key.playSoundOnCapture) ?? true
        }
        set { withMutation(keyPath: \.playSoundOnCapture) { store.set(newValue, forKey: Key.playSoundOnCapture) } }
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

    /// 60 fps by default: scrolling and pointer motion stay smooth, and 30 fps is there for smaller files.
    public var recordingFrameRate: RecordingFrameRate {
        get {
            access(keyPath: \.recordingFrameRate)
            return store.double(forKey: Key.recordingFrameRate).flatMap { RecordingFrameRate(rawValue: Int($0)) } ?? .sixty
        }
        set { withMutation(keyPath: \.recordingFrameRate) { store.set(Double(newValue.rawValue), forKey: Key.recordingFrameRate) } }
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

    /// nil records the system default input. The name stays with the ID so a missing input can still be named.
    public var recordingInput: AudioInput? {
        get {
            access(keyPath: \.recordingInput)
            guard let id = store.string(forKey: Key.recordingInputID), !id.isEmpty else { return nil }
            return AudioInput(id: id, name: store.string(forKey: Key.recordingInputName) ?? id)
        }
        set {
            withMutation(keyPath: \.recordingInput) {
                store.set(newValue?.id, forKey: Key.recordingInputID)
                store.set(newValue?.name, forKey: Key.recordingInputName)
            }
        }
    }

    /// Off by default: the camera shows the user's face in the video, so they ask for it.
    public var recordCamera: Bool {
        get {
            access(keyPath: \.recordCamera)
            return store.bool(forKey: Key.recordCamera) ?? false
        }
        set { withMutation(keyPath: \.recordCamera) { store.set(newValue, forKey: Key.recordCamera) } }
    }

    /// nil shows the system's preferred camera. The name stays with the ID so a missing camera can still be named.
    public var recordingCamera: CameraInput? {
        get {
            access(keyPath: \.recordingCamera)
            guard let id = store.string(forKey: Key.recordingCameraID), !id.isEmpty else { return nil }
            return CameraInput(id: id, name: store.string(forKey: Key.recordingCameraName) ?? id)
        }
        set {
            withMutation(keyPath: \.recordingCamera) {
                store.set(newValue?.id, forKey: Key.recordingCameraID)
                store.set(newValue?.name, forKey: Key.recordingCameraName)
            }
        }
    }

    /// The camera bubble's size in points, as last resized, clamped to `CameraBubbleGeometry`'s limits. A small area
    /// shrinks the bubble further while it's shown, without changing what's saved.
    public var cameraBubbleDiameter: Double {
        get {
            access(keyPath: \.cameraBubbleDiameter)
            return Self.clampDiameter(store.double(forKey: Key.cameraBubbleDiameter) ?? Double(CameraBubbleGeometry.defaultDiameter))
        }
        set { withMutation(keyPath: \.cameraBubbleDiameter) { store.set(Self.clampDiameter(newValue), forKey: Key.cameraBubbleDiameter) } }
    }

    private static func clampDiameter(_ diameter: Double) -> Double {
        guard diameter.isFinite else { return Double(CameraBubbleGeometry.defaultDiameter) }
        return min(max(diameter, Double(CameraBubbleGeometry.minDiameter)), Double(CameraBubbleGeometry.maxDiameter))
    }

    /// Off by default: showing keys needs Input Monitoring, and typed text ends up in the video.
    public var showPressedKeys: Bool {
        get {
            access(keyPath: \.showPressedKeys)
            return store.bool(forKey: Key.showPressedKeys) ?? false
        }
        set { withMutation(keyPath: \.showPressedKeys) { store.set(newValue, forKey: Key.showPressedKeys) } }
    }

    public var showMouseClicks: Bool {
        get {
            access(keyPath: \.showMouseClicks)
            return store.bool(forKey: Key.showMouseClicks) ?? false
        }
        set { withMutation(keyPath: \.showMouseClicks) { store.set(newValue, forKey: Key.showMouseClicks) } }
    }

    public var recordingChoices: RecordingChoices {
        RecordingChoices(
            systemAudio: recordSystemAudio,
            microphone: recordMicrophone,
            input: recordingInput,
            camera: recordCamera,
            cameraInput: recordingCamera,
            showsKeys: showPressedKeys,
            showsClicks: showMouseClicks
        )
    }

    /// On by default: three seconds to get the pointer and the window ready before the first frame, like CleanShot.
    public var recordingCountdown: Bool {
        get {
            access(keyPath: \.recordingCountdown)
            return store.bool(forKey: Key.recordingCountdown) ?? true
        }
        set { withMutation(keyPath: \.recordingCountdown) { store.set(newValue, forKey: Key.recordingCountdown) } }
    }

    /// On by default: a recording starts and ends while the user looks at something else, so they hear it.
    public var recordingSounds: Bool {
        get {
            access(keyPath: \.recordingSounds)
            return store.bool(forKey: Key.recordingSounds) ?? true
        }
        set { withMutation(keyPath: \.recordingSounds) { store.set(newValue, forKey: Key.recordingSounds) } }
    }

    /// Hidden: on records the screen, camera and input events as separate files in a project and renders the video from
    /// them; off films everything into one file, as before slice 2 retires that path.
    public var recordsRaw: Bool {
        get {
            access(keyPath: \.recordsRaw)
            return store.bool(forKey: Key.recordsRaw) ?? true
        }
        set { withMutation(keyPath: \.recordsRaw) { store.set(newValue, forKey: Key.recordsRaw) } }
    }

    /// Renders bigger than 3840x2160 are scaled to fit inside it unless this is off.
    public var capsRenderToUHD: Bool {
        get {
            access(keyPath: \.capsRenderToUHD)
            return store.bool(forKey: Key.capsRenderToUHD) ?? true
        }
        set { withMutation(keyPath: \.capsRenderToUHD) { store.set(newValue, forKey: Key.capsRenderToUHD) } }
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

    /// Off by default: a compressed screenshot keeps at most 256 colors, so photos in it can band.
    public var compressAfterCapture: Bool {
        get {
            access(keyPath: \.compressAfterCapture)
            return store.bool(forKey: Key.compressAfterCapture) ?? false
        }
        set { withMutation(keyPath: \.compressAfterCapture) { store.set(newValue, forKey: Key.compressAfterCapture) } }
    }

    /// Off by default: it watches everything copied in every app, and swaps copied images for 256-color ones.
    public var compressCopiedMedia: Bool {
        get {
            access(keyPath: \.compressCopiedMedia)
            return store.bool(forKey: Key.compressCopiedMedia) ?? false
        }
        set { withMutation(keyPath: \.compressCopiedMedia) { store.set(newValue, forKey: Key.compressCopiedMedia) } }
    }

    public var pickerPromptExplained: Bool {
        get {
            access(keyPath: \.pickerPromptExplained)
            return store.bool(forKey: Key.pickerPromptExplained) ?? false
        }
        set { withMutation(keyPath: \.pickerPromptExplained) { store.set(newValue, forKey: Key.pickerPromptExplained) } }
    }

    public static let defaultAnnotationColor = "#FF3B30"

    public var annotationColor: String {
        get {
            access(keyPath: \.annotationColor)
            guard let raw = store.string(forKey: Key.annotationColor), Self.isValidHexColor(raw) else {
                return Self.defaultAnnotationColor
            }
            return raw.uppercased()
        }
        set {
            let normalized = Self.isValidHexColor(newValue) ? newValue.uppercased() : Self.defaultAnnotationColor
            withMutation(keyPath: \.annotationColor) { store.set(normalized, forKey: Key.annotationColor) }
        }
    }

    private static func isValidHexColor(_ value: String) -> Bool {
        guard value.count == 7, value.first == "#" else { return false }
        return value.dropFirst().allSatisfy(\.isHexDigit)
    }
}
