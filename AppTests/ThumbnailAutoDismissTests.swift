import AppKit
import GlintCore
import Testing
@testable import Glint

final class Defaults: KeyValueStore {
    var values: [String: Any] = [:]
    func string(forKey key: String) -> String? { values[key] as? String }
    func set(_ value: String?, forKey key: String) { values[key] = value }
    func bool(forKey key: String) -> Bool? { values[key] as? Bool }
    func set(_ value: Bool, forKey key: String) { values[key] = value }
    func double(forKey key: String) -> Double? { values[key] as? Double }
    func set(_ value: Double, forKey key: String) { values[key] = value }
}

@MainActor func writePNG() throws -> URL {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 30, pixelsHigh: 20, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let url = FileManager.default.temporaryDirectory.appending(path: "glint-thumb-\(UUID().uuidString).png")
    try rep.representation(using: .png, properties: [:])!.write(to: url)
    return url
}

let offScreen = CGPoint(x: -10_000, y: -10_000) // the real pointer could hover a card and pause auto-hide

@MainActor @Test func autoHideWaitsUntilStackingStopsThenHidesThePileTogether() async throws {
    let settings = GlintSettings(store: Defaults(), defaultSaveFolder: FileManager.default.temporaryDirectory)
    settings.overlayAutoDismiss = true
    let presenter = ThumbnailPresenter(settings: settings, autoDismissDelay: .seconds(1), pointerLocation: { offScreen })

    presenter.show(try writePNG())
    try await Task.sleep(for: .milliseconds(600))
    presenter.show(try writePNG()) // still stacking: restarts the countdown
    try await Task.sleep(for: .milliseconds(600))
    #expect(presenter.count == 2) // 1.2 s after the first capture, nothing has gone yet

    try await Task.sleep(for: .seconds(1))
    #expect(presenter.count == 0) // the whole pile went together
}

@MainActor @Test func autoHideOffKeepsThumbnails() async throws {
    let settings = GlintSettings(store: Defaults(), defaultSaveFolder: FileManager.default.temporaryDirectory)
    let presenter = ThumbnailPresenter(settings: settings, autoDismissDelay: .milliseconds(100), pointerLocation: { offScreen })
    presenter.show(try writePNG())
    try await Task.sleep(for: .milliseconds(300))
    #expect(presenter.count == 1)
}
