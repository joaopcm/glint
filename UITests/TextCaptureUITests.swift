import AppKit
import XCTest

final class TextCaptureUITests: GlintUITestCase {
    static let knownText = "Glint reads this line"
    /// The first recognition on a machine that never ran Vision took 27.4 s locally (`swift test` in GlintCapture); warm runs take 0.15 s.
    static let recognitionTimeout: TimeInterval = 60

    @MainActor func testDragOverTextCopiesItAndSavesNothing() throws {
        let window = try openTextEditWindow(showing: Self.knownText)
        let frame = window.frame
        NSPasteboard.general.clearContents()

        press(.text)
        waitForOverlay(after: .text)
        screenPoint(CGPoint(x: frame.minX + 4, y: frame.minY + 4))
            .press(forDuration: 0.1, thenDragTo: screenPoint(CGPoint(x: frame.maxX - 4, y: frame.maxY - 4)))

        let deadline = Date().addingTimeInterval(Self.recognitionTimeout)
        var copied = ""
        while !copied.contains(Self.knownText), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            copied = NSPasteboard.general.string(forType: .string) ?? ""
        }
        XCTAssertTrue(
            copied.contains(Self.knownText),
            "\(Self.recognitionTimeout) s after \(Hotkey.text.rawValue) the clipboard holds \(copied.debugDescription), expected it to contain \"\(Self.knownText)\". \(app.debugDescription)"
        )
        XCTAssertNil(NSPasteboard.general.data(forType: .png), "a text capture put an image on the clipboard")
        assertPNGCount(0)
        XCTAssertFalse(app.images.matching(NSPredicate(format: "label BEGINSWITH 'Screenshot '")).firstMatch.exists, "a text capture showed a thumbnail")
    }

    @MainActor private func openTextEditWindow(showing text: String) throws -> XCUIElement {
        let folder = FileManager.default.temporaryDirectory.appending(path: "GlintTextUITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "glint-ocr-\(UUID().uuidString.prefix(8))"
        let file = folder.appending(path: "\(name).rtf")
        try #"{\rtf1\ansi{\fonttbl\f0 Helvetica;}\f0\fs72 \#(text)\par}"#.write(to: file, atomically: true, encoding: .utf8)
        let textEdit = XCUIApplication(bundleIdentifier: "com.apple.TextEdit")
        addTeardownBlock { @MainActor in
            textEdit.terminate()
            try? FileManager.default.removeItem(at: folder)
        }
        NSWorkspace.shared.open([file], withApplicationAt: URL(filePath: "/System/Applications/TextEdit.app"), configuration: NSWorkspace.OpenConfiguration())
        let window = textEdit.windows.matching(NSPredicate(format: "title BEGINSWITH %@", name)).firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: Self.captureTimeout), "TextEdit did not open \(file.path). TextEdit windows: \(textEdit.windows.debugDescription)")
        return window
    }
}
