import Foundation
import Observation
import Testing
@testable import GlintCore

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
    let settings = GlintSettings(store: MemoryStore(), defaultSaveFolder: desktop)
    #expect(settings.saveFolder == desktop)
    #expect(settings.copyToClipboardAfterCapture == false)
}

@MainActor @Test func saveFolderRoundTripsAsPath() {
    let store = MemoryStore()
    let folder = URL(filePath: "/tmp/shots")
    GlintSettings(store: store, defaultSaveFolder: desktop).saveFolder = folder
    #expect(store.string(forKey: "saveFolderPath") == "/tmp/shots")
    #expect(GlintSettings(store: store, defaultSaveFolder: desktop).saveFolder.path == folder.path)
}

@MainActor @Test func clipboardRoundTrips() {
    let store = MemoryStore()
    GlintSettings(store: store, defaultSaveFolder: desktop).copyToClipboardAfterCapture = true
    #expect(GlintSettings(store: store, defaultSaveFolder: desktop).copyToClipboardAfterCapture == true)
}

@MainActor @Test func emptyStoredPathFallsBackToDefault() {
    let store = MemoryStore()
    store.set("", forKey: "saveFolderPath")
    #expect(GlintSettings(store: store, defaultSaveFolder: desktop).saveFolder == desktop)
}

@MainActor @Test func overlaySettingsDefaultAndRoundTrip() {
    let store = MemoryStore()
    let settings = GlintSettings(store: store, defaultSaveFolder: desktop)
    #expect(settings.overlayCorner == .bottomRight)
    #expect(settings.overlayAutoDismiss == false)
    settings.overlayCorner = .bottomLeft
    settings.overlayAutoDismiss = true
    let reloaded = GlintSettings(store: store, defaultSaveFolder: desktop)
    #expect(reloaded.overlayCorner == .bottomLeft)
    #expect(reloaded.overlayAutoDismiss == true)
}

@MainActor @Test func unknownCornerFallsBackToDefault() {
    let store = MemoryStore()
    store.set("topMiddle", forKey: "overlayCorner")
    #expect(GlintSettings(store: store, defaultSaveFolder: desktop).overlayCorner == .bottomRight)
}

@MainActor @Test func thumbnailWidthDefaultsRoundTripsAndClamps() {
    let store = MemoryStore()
    let settings = GlintSettings(store: store, defaultSaveFolder: desktop)
    #expect(settings.thumbnailWidth == 240)
    settings.thumbnailWidth = 300
    #expect(GlintSettings(store: store, defaultSaveFolder: desktop).thumbnailWidth == 300)
    settings.thumbnailWidth = 5000
    #expect(settings.thumbnailWidth == 480)
    store.set(10.0, forKey: "thumbnailWidth") // out-of-range value already on disk
    #expect(settings.thumbnailWidth == 190)
    #expect(GlintSettings.clampWidth(.nan) == 240)
}

private final class ChangeFlag: @unchecked Sendable {
    var raised = false
}

@MainActor private func changeIsSeen<Value: Equatable>(
    _ keyPath: ReferenceWritableKeyPath<GlintSettings, Value>,
    becomes value: Value
) -> Bool {
    let settings = GlintSettings(store: MemoryStore(), defaultSaveFolder: desktop)
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
}

@MainActor @Test func uploadAfterCaptureDefaultsOffAndRoundTrips() {
    let store = MemoryStore()
    #expect(GlintSettings(store: store, defaultSaveFolder: desktop).uploadAfterCapture == false)
    GlintSettings(store: store, defaultSaveFolder: desktop).uploadAfterCapture = true
    #expect(GlintSettings(store: store, defaultSaveFolder: desktop).uploadAfterCapture == true)
}

@MainActor @Test func freezeScreenDefaultsOffAndRoundTrips() {
    let store = MemoryStore()
    #expect(GlintSettings(store: store, defaultSaveFolder: desktop).freezeScreenWhileSelecting == false)
    GlintSettings(store: store, defaultSaveFolder: desktop).freezeScreenWhileSelecting = true
    #expect(GlintSettings(store: store, defaultSaveFolder: desktop).freezeScreenWhileSelecting == true)
}
