import Foundation
import Observation
import Testing
@testable import LunettaCore

final class MemoryStore: KeyValueStore {
    var values: [String: Any] = [:]
    func string(forKey key: String) -> String? { values[key] as? String }
    func set(_ value: String?, forKey key: String) { values[key] = value }
    func bool(forKey key: String) -> Bool? { values[key] as? Bool }
    func set(_ value: Bool, forKey key: String) { values[key] = value }
    func double(forKey key: String) -> Double? { values[key] as? Double }
    func set(_ value: Double, forKey key: String) { values[key] = value }
}

private let desktop = URL(filePath: "/Users/me/Desktop")

@MainActor @Test func defaultsWhenEmpty() {
    let settings = LunettaSettings(store: MemoryStore(), defaultSaveFolder: desktop)
    #expect(settings.saveFolder == desktop)
    #expect(settings.copyToClipboardAfterCapture == false)
}

@MainActor @Test func saveFolderRoundTripsAsPath() {
    let store = MemoryStore()
    let folder = URL(filePath: "/tmp/shots")
    LunettaSettings(store: store, defaultSaveFolder: desktop).saveFolder = folder
    #expect(store.string(forKey: "saveFolderPath") == "/tmp/shots")
    #expect(LunettaSettings(store: store, defaultSaveFolder: desktop).saveFolder.path == folder.path)
}

@MainActor @Test func clipboardRoundTrips() {
    let store = MemoryStore()
    LunettaSettings(store: store, defaultSaveFolder: desktop).copyToClipboardAfterCapture = true
    #expect(LunettaSettings(store: store, defaultSaveFolder: desktop).copyToClipboardAfterCapture == true)
}

@MainActor @Test func emptyStoredPathFallsBackToDefault() {
    let store = MemoryStore()
    store.set("", forKey: "saveFolderPath")
    #expect(LunettaSettings(store: store, defaultSaveFolder: desktop).saveFolder == desktop)
}

@MainActor @Test func overlaySettingsDefaultAndRoundTrip() {
    let store = MemoryStore()
    let settings = LunettaSettings(store: store, defaultSaveFolder: desktop)
    #expect(settings.overlayCorner == .bottomRight)
    #expect(settings.overlayAutoDismiss == false)
    settings.overlayCorner = .bottomLeft
    settings.overlayAutoDismiss = true
    let reloaded = LunettaSettings(store: store, defaultSaveFolder: desktop)
    #expect(reloaded.overlayCorner == .bottomLeft)
    #expect(reloaded.overlayAutoDismiss == true)
}

@MainActor @Test func unknownCornerFallsBackToDefault() {
    let store = MemoryStore()
    store.set("topMiddle", forKey: "overlayCorner")
    #expect(LunettaSettings(store: store, defaultSaveFolder: desktop).overlayCorner == .bottomRight)
}

@MainActor @Test func thumbnailWidthDefaultsRoundTripsAndClamps() {
    let store = MemoryStore()
    let settings = LunettaSettings(store: store, defaultSaveFolder: desktop)
    #expect(settings.thumbnailWidth == 240)
    settings.thumbnailWidth = 300
    #expect(LunettaSettings(store: store, defaultSaveFolder: desktop).thumbnailWidth == 300)
    settings.thumbnailWidth = 5000
    #expect(settings.thumbnailWidth == 480)
    store.set(10.0, forKey: "thumbnailWidth") // out-of-range value already on disk
    #expect(settings.thumbnailWidth == 190)
    #expect(LunettaSettings.clampWidth(.nan) == 240)
}

@MainActor @Test func windowWallpaperDefaultsOffAndPaddingRoundTripsAndClamps() {
    let store = MemoryStore()
    let settings = LunettaSettings(store: store, defaultSaveFolder: desktop)
    #expect(settings.windowCaptureWallpaper == false)
    #expect(settings.windowWallpaperPadding == 64)
    #expect(settings.wallpaperPaddingForWindowCaptures == nil)
    settings.windowCaptureWallpaper = true
    settings.windowWallpaperPadding = 120
    let reloaded = LunettaSettings(store: store, defaultSaveFolder: desktop)
    #expect(reloaded.windowCaptureWallpaper == true)
    #expect(reloaded.wallpaperPaddingForWindowCaptures == 120)
    settings.windowWallpaperPadding = 5000
    #expect(settings.windowWallpaperPadding == 256)
    store.set(-10.0, forKey: "windowWallpaperPadding")
    #expect(settings.windowWallpaperPadding == 0)
    #expect(LunettaSettings.clampPadding(.nan) == 64)
}

private final class ChangeFlag: @unchecked Sendable {
    var raised = false
}

@MainActor private func changeIsSeen<Value: Equatable>(
    _ keyPath: ReferenceWritableKeyPath<LunettaSettings, Value>,
    becomes value: Value
) -> Bool {
    let settings = LunettaSettings(store: MemoryStore(), defaultSaveFolder: desktop)
    let settingsWindow = settings
    let resizeGesture = settings
    let changed = ChangeFlag()
    withObservationTracking { _ = settingsWindow[keyPath: keyPath] } onChange: { changed.raised = true }
    resizeGesture[keyPath: keyPath] = value
    return changed.raised && settingsWindow[keyPath: keyPath] == value
}

@MainActor @Test func changeThroughOneReferenceIsSeenThroughTheOther() {
    #expect(changeIsSeen(\.saveFolder, becomes: URL(filePath: "/tmp/shots")))
    #expect(changeIsSeen(\.copyToClipboardAfterCapture, becomes: true))
    #expect(changeIsSeen(\.overlayCorner, becomes: .bottomLeft))
    #expect(changeIsSeen(\.overlayAutoDismiss, becomes: true))
    #expect(changeIsSeen(\.thumbnailWidth, becomes: 300))
    #expect(changeIsSeen(\.freezeScreenWhileSelecting, becomes: true))
    #expect(changeIsSeen(\.showMagnifierWhileSelecting, becomes: true))
    #expect(changeIsSeen(\.windowCaptureWallpaper, becomes: true))
    #expect(changeIsSeen(\.windowWallpaperPadding, becomes: 120))
    #expect(changeIsSeen(\.recordingCodec, becomes: .hevc))
    #expect(changeIsSeen(\.recordSystemAudio, becomes: true))
    #expect(changeIsSeen(\.recordMicrophone, becomes: true))
}

@MainActor @Test func audioTogglesDefaultOffAndAreRemembered() {
    let store = MemoryStore()
    let first = LunettaSettings(store: store, defaultSaveFolder: desktop)
    #expect(first.recordSystemAudio == false && first.recordMicrophone == false)
    first.recordSystemAudio = true
    first.recordMicrophone = true
    let next = LunettaSettings(store: store, defaultSaveFolder: desktop)
    #expect(next.recordSystemAudio && next.recordMicrophone)
}

@MainActor @Test func recordingCodecDefaultsToH264RoundTripsAndIgnoresUnknownValues() {
    let store = MemoryStore()
    #expect(LunettaSettings(store: store, defaultSaveFolder: desktop).recordingCodec == .h264)
    LunettaSettings(store: store, defaultSaveFolder: desktop).recordingCodec = .hevc
    #expect(LunettaSettings(store: store, defaultSaveFolder: desktop).recordingCodec == .hevc)
    store.set("prores", forKey: "recordingCodec")
    #expect(LunettaSettings(store: store, defaultSaveFolder: desktop).recordingCodec == .h264)
}

@MainActor @Test func uploadAfterCaptureDefaultsOffAndRoundTrips() {
    let store = MemoryStore()
    #expect(LunettaSettings(store: store, defaultSaveFolder: desktop).uploadAfterCapture == false)
    LunettaSettings(store: store, defaultSaveFolder: desktop).uploadAfterCapture = true
    #expect(LunettaSettings(store: store, defaultSaveFolder: desktop).uploadAfterCapture == true)
}

@MainActor @Test func pickerPromptExplainedDefaultsOffAndRoundTrips() {
    let store = MemoryStore()
    #expect(LunettaSettings(store: store, defaultSaveFolder: desktop).pickerPromptExplained == false)
    LunettaSettings(store: store, defaultSaveFolder: desktop).pickerPromptExplained = true
    #expect(LunettaSettings(store: store, defaultSaveFolder: desktop).pickerPromptExplained == true)
}

@MainActor @Test func freezeScreenDefaultsOffAndRoundTrips() {
    let store = MemoryStore()
    #expect(LunettaSettings(store: store, defaultSaveFolder: desktop).freezeScreenWhileSelecting == false)
    LunettaSettings(store: store, defaultSaveFolder: desktop).freezeScreenWhileSelecting = true
    #expect(LunettaSettings(store: store, defaultSaveFolder: desktop).freezeScreenWhileSelecting == true)
}

@MainActor @Test func magnifierDefaultsOffAndRoundTrips() {
    let store = MemoryStore()
    #expect(LunettaSettings(store: store, defaultSaveFolder: desktop).showMagnifierWhileSelecting == false)
    LunettaSettings(store: store, defaultSaveFolder: desktop).showMagnifierWhileSelecting = true
    #expect(LunettaSettings(store: store, defaultSaveFolder: desktop).showMagnifierWhileSelecting == true)
}
