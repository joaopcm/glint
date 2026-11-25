import Foundation
import Testing
@testable import Lunetta

@MainActor @Test func missingCaptureNamesThePathAndReason() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "lunetta-missing-\(UUID().uuidString).png")
    let error = try #require(throws: CaptureEditorError.self) { try CaptureEditor.image(at: url) }
    #expect(error == .unreadable(path: url.path, reason: "No such file or directory"))
    #expect(error.errorDescription == "Lunetta couldn't read \(url.path): No such file or directory.")
}

@MainActor @Test func nonImageCaptureSaysItCouldNotBeDecoded() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "lunetta-garbage-\(UUID().uuidString).png")
    try Data("not a png".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let error = try #require(throws: CaptureEditorError.self) { try CaptureEditor.image(at: url) }
    #expect(error == .unreadable(path: url.path, reason: "ImageIO could not decode it as an image"))
}
