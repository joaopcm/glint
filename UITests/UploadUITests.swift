import AppKit
import XCTest

final class UploadUITests: GlintUITestCase {
    static let publicBaseURL = "https://shots.example.test/glint"
    private var server: StubS3Server!
    private var historyFile: URL!

    override var extraLaunchArguments: [String] {
        [
            "-bucketEndpoint", "http://127.0.0.1:\(server.port)",
            "-bucketRegion", "us-east-1",
            "-bucketName", "shots",
            "-bucketPathStyle", "YES",
            "-bucketKeyPrefix", "uitest",
            "-bucketPublicBaseURL", Self.publicBaseURL,
            "-uploadAfterCapture", "NO",
        ]
    }

    override var extraLaunchEnvironment: [String: String] {
        [
            "GLINT_UI_TEST_ACCESS_KEY_ID": "AKIAIOSFODNN7EXAMPLE",
            "GLINT_UI_TEST_SECRET_ACCESS_KEY": "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            "GLINT_UI_TEST_UPLOAD_HISTORY": historyFile.path,
        ]
    }

    override func setUpWithError() throws {
        server = try StubS3Server()
        historyFile = FileManager.default.temporaryDirectory.appending(path: "GlintUITests-history-\(UUID().uuidString).json")
        try super.setUpWithError()
    }

    override func tearDownWithError() throws {
        try super.tearDownWithError()
        server?.stop()
        if let historyFile {
            try? FileManager.default.removeItem(at: historyFile)
        }
    }

    @MainActor func testUploadPutsTheCaptureInlineAndCopiesItsLink() throws {
        let (png, card) = try uploadAFullScreenCapture()

        let requests = server.requests
        XCTAssertEqual(requests.count, 1, "the stub bucket got \(requests.map { "\($0.method) \($0.path)" })")
        let put = try XCTUnwrap(requests.first)
        XCTAssertEqual(put.method, "PUT")
        XCTAssertEqual(put.headers["content-type"], "image/png")
        XCTAssertEqual(put.headers["content-disposition"], "inline")
        XCTAssertEqual(put.body, try Data(contentsOf: png), "the PUT body isn't the capture")
        XCTAssertNotNil(put.path.range(of: #"^/shots/uitest/[0-9A-Za-z]{16}\.png$"#, options: .regularExpression), "object path is \(put.path)")

        let key = put.path.dropFirst("/shots/".count)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "\(Self.publicBaseURL)/\(key)")
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: card)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: Self.captureTimeout), .completed, "Upload left the card on screen")
    }

    @MainActor func testDeletingAnUploadFromHistoryDeletesTheObjectAndTheRow() throws {
        _ = try uploadAFullScreenCapture()
        let put = try XCTUnwrap(server.requests.first, "the upload never reached the stub bucket")
        let link = "\(Self.publicBaseURL)/\(put.path.dropFirst("/shots/".count))"

        openHistoryTab()
        let row = app.descendants(matching: .any).matching(identifier: AccessibilityID.uploadHistoryLink).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: Self.captureTimeout), "History lists no upload")
        XCTAssertEqual("\(row.value ?? row.label)", link, "History lists the wrong link")
        let delete = app.descendants(matching: .any).matching(identifier: AccessibilityID.deleteUpload).firstMatch
        XCTAssertTrue(delete.exists, "the History row has no Delete button")
        delete.click()

        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: row)
        let error = app.descendants(matching: .any).matching(identifier: AccessibilityID.uploadHistoryError).firstMatch
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: Self.captureTimeout), .completed,
                       "Delete left the row. \(error.exists ? "History says: \(error.value ?? error.label)" : "History shows no error.")")
        let requests = server.requests.map { "\($0.method) \($0.path)" }
        XCTAssertEqual(requests, ["PUT \(put.path)", "DELETE \(put.path)"])
    }

    @MainActor private func uploadAFullScreenCapture() throws -> (png: URL, card: XCUIElement) {
        NSPasteboard.general.clearContents()
        press(.fullScreen)
        let png = try XCTUnwrap(waitForPNGs(count: 1, after: .fullScreen).first)
        let card = app.images["Screenshot \(png.lastPathComponent)"]
        XCTAssertTrue(card.waitForExistence(timeout: Self.captureTimeout), "no thumbnail for \(png.lastPathComponent)")
        center(of: card).hover()
        let upload = app.buttons["Upload"].firstMatch
        XCTAssertTrue(upload.waitForExistence(timeout: Self.captureTimeout), "hovering shows no Upload button")
        center(of: upload).click()

        let deadline = Date().addingTimeInterval(Self.captureTimeout)
        while NSPasteboard.general.string(forType: .string) == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return (png, card)
    }

    @MainActor private func openHistoryTab() {
        let statusItem = app.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: Self.captureTimeout), "Glint's menu bar icon is missing")
        statusItem.click()
        statusItem.descendants(matching: .menuItem)["Settings…"].click()
        // Settings toolbar tabs are buttons whose label is sometimes empty (ui.xcresult of run 45478719380).
        let historyTab = app.buttons.matching(NSPredicate(format: "title == %@ OR label == %@", "History", "History")).firstMatch
        XCTAssertTrue(historyTab.waitForExistence(timeout: Self.captureTimeout), "Settings has no History tab")
        historyTab.click()
    }
}
