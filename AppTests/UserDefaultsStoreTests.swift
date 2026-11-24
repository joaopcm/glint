import Foundation
import GlintCore
import Testing
@testable import Glint

@MainActor @Test func settingsSurviveANewStoreOnTheSameSuite() throws {
    let suite = "GlintTests-\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let folder = URL(filePath: "/tmp/glint-saved-elsewhere")
    let fallback = FileManager.default.temporaryDirectory

    let before = GlintSettings(store: UserDefaultsStore(defaults: try #require(UserDefaults(suiteName: suite))), defaultSaveFolder: fallback)
    before.saveFolder = folder
    before.copyToClipboardAfterCapture = true
    before.overlayCorner = .bottomLeft
    before.thumbnailWidth = 300
    before.freezeScreenWhileSelecting = true

    let after = GlintSettings(store: UserDefaultsStore(defaults: try #require(UserDefaults(suiteName: suite))), defaultSaveFolder: fallback)
    #expect(after.saveFolder.path == folder.path)
    #expect(after.copyToClipboardAfterCapture)
    #expect(after.overlayCorner == .bottomLeft)
    #expect(after.thumbnailWidth == 300)
    #expect(after.freezeScreenWhileSelecting)
}

/// `-key value` launch arguments land in the argument domain as strings; the UI tests rely on them.
@MainActor @Test func launchArgumentStringsReadAsBoolAndDouble() throws {
    let suite = "GlintTests-\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.set("YES", forKey: "freezeScreenWhileSelecting")
    defaults.set("240", forKey: "thumbnailWidth")

    let store = UserDefaultsStore(defaults: defaults)
    #expect(store.bool(forKey: "freezeScreenWhileSelecting") == true)
    #expect(store.double(forKey: "thumbnailWidth") == 240)
    #expect(store.bool(forKey: "absent") == nil)
    #expect(store.double(forKey: "absent") == nil)
}
