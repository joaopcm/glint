import Foundation
import Testing
@testable import Glint

@MainActor @Test func missingCaptureNamesThePathAndReason() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "glint-missing-\(UUID().uuidString).png")
    let error = try #require(throws: CaptureEditorError.self) { try CaptureEditor.image(at: url) }
    #expect(error == .unreadable(path: url.path, reason: "No such file or directory"))
    #expect(error.errorDescription == "Glint couldn't read \(url.path): No such file or directory.")
}

@MainActor @Test func nonImageCaptureSaysItCouldNotBeDecoded() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "glint-garbage-\(UUID().uuidString).png")
    try Data("not a png".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let error = try #require(throws: CaptureEditorError.self) { try CaptureEditor.image(at: url) }
    #expect(error == .unreadable(path: url.path, reason: "ImageIO could not decode it as an image"))
}
