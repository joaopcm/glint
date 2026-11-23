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

    let after = GlintSettings(store: UserDefaultsStore(defaults: try #require(UserDefaults(suiteName: suite))), defaultSaveFolder: fallback)
    #expect(after.saveFolder.path == folder.path)
    #expect(after.copyToClipboardAfterCapture)
    #expect(after.overlayCorner == .bottomLeft)
    #expect(after.thumbnailWidth == 300)
}
