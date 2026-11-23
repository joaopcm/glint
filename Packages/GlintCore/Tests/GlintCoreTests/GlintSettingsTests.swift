import Foundation
import Testing
@testable import GlintCore

final class MemoryStore: KeyValueStore {
    var values: [String: Any] = [:]
    func string(forKey key: String) -> String? { values[key] as? String }
    func set(_ value: String?, forKey key: String) { values[key] = value }
    func bool(forKey key: String) -> Bool? { values[key] as? Bool }
    func set(_ value: Bool, forKey key: String) { values[key] = value }
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
