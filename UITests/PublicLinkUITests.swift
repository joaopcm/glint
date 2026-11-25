import AppKit
import XCTest

final class PublicLinkUITests: LunettaUITestCase {
    private var server: StubS3Server!

    override var extraLaunchArguments: [String] {
        [
            "-bucketEndpoint", "http://127.0.0.1:\(server.port)",
            "-bucketRegion", "us-east-1",
            "-bucketName", "shots",
            "-bucketPathStyle", "YES",
            "-bucketKeyPrefix", "uitest",
            "-bucketPublicBaseURL", "",
        ]
    }

    override var extraLaunchEnvironment: [String: String] {
        [
            "LUNETTA_UI_TEST_ACCESS_KEY_ID": "AKIAIOSFODNN7EXAMPLE",
            "LUNETTA_UI_TEST_SECRET_ACCESS_KEY": "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        ]
    }

    override func setUpWithError() throws {
        server = try StubS3Server(deniedMethods: ["DELETE"])
        try super.setUpWithError()
    }

    override func tearDownWithError() throws {
        try super.tearDownWithError()
        server?.stop()
    }

    @MainActor func testTestConnectionShowsAChecklistWithTheFailedStepExpanded() {
        let statusItem = app.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: Self.captureTimeout), "Lunetta's menu bar icon is missing")
        statusItem.click()
        statusItem.descendants(matching: .menuItem)["Settings…"].click()
        // The Settings toolbar tab is a button titled "Upload" whose label is sometimes empty (ui.xcresult of run 45478719380).
        let uploadTab = app.buttons.matching(NSPredicate(format: "title == %@ OR label == %@", "Upload", "Upload")).firstMatch
        XCTAssertTrue(uploadTab.waitForExistence(timeout: Self.captureTimeout), "Settings has no Upload tab")
        uploadTab.click()

        let testConnection = app.descendants(matching: .any).matching(identifier: AccessibilityID.testConnection).firstMatch
        XCTAssertTrue(testConnection.waitForExistence(timeout: Self.captureTimeout), "the Upload tab has no Test Connection button")
        testConnection.click()

        let delete = step("delete")
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "failed"), object: delete)
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: Self.captureTimeout), .completed, "the delete row never failed: \(describe(delete))")

        assertStep("upload", status: "passed", reads: ["Upload a test file", "These keys can write to shots."])
        assertStep("publicLink", status: "warning", reads: [
            "Copied links open",
            "Copied links won't open: the bucket isn't publicly readable (HTTP 403 AccessDenied).",
        ])
        assertStep("delete", status: "failed", reads: [
            "Delete the test file",
            "shots refused the request: these keys don't have s3:DeleteObject. The test file is still in the bucket.",
        ])

        let deleteFix = app.staticTexts.matching(NSPredicate(
            format: "value BEGINSWITH %@ AND value CONTAINS %@",
            "Add s3:DeleteObject on arn:aws:s3:::shots/uitest/* to the IAM policy of these keys.",
            "Delete it by hand: uitest/lunetta-connection-test-"
        )).firstMatch
        XCTAssertTrue(deleteFix.exists, "the failed delete row isn't expanded with its fix")
        let deleteError = app.staticTexts.matching(NSPredicate(format: "value == %@", "AccessDenied: Access Denied")).firstMatch
        XCTAssertTrue(deleteError.exists, "the expanded rows don't show the S3 error code and message")
        let hint = app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "mc anonymous set download <alias>/shots/uitest")).firstMatch
        XCTAssertTrue(hint.exists, "the warning row isn't expanded with the MinIO hint")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: AccessibilityID.makeLinksPublic).firstMatch.exists, "Make Links Public shows for a non-AWS endpoint")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "title == %@ OR label == %@", "Copy Details", "Copy Details")).firstMatch.exists, "no Copy Details button")
        let onScreen = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: deleteFix)
        XCTAssertEqual(XCTWaiter.wait(for: [onScreen], timeout: Self.captureTimeout), .completed, "the failed row's fix never scrolled on screen")
        keepScreenshot(named: "connection checklist")

        let requests = server.requests.map { "\($0.method) \($0.path) signed=\($0.headers["authorization"] != nil)" }
        XCTAssertEqual(requests.count, 3, "\(requests)")
        XCTAssertTrue(requests[1].hasPrefix("GET /shots/uitest/lunetta-connection-test-") && requests[1].hasSuffix("signed=false"), "\(requests)")
        XCTAssertTrue(requests[2].hasPrefix("DELETE /shots/uitest/lunetta-connection-test-"), "\(requests)")
    }

    @MainActor private func step(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: AccessibilityID.connectionStep(id)).firstMatch
    }

    @MainActor private func describe(_ element: XCUIElement) -> String {
        element.exists ? "value=\(element.value ?? "nil") label=\(element.label)" : "missing"
    }

    @MainActor private func assertStep(_ id: String, status: String, reads texts: [String], file: StaticString = #filePath, line: UInt = #line) {
        let row = step(id)
        XCTAssertTrue(row.exists, "no \(id) row", file: file, line: line)
        XCTAssertEqual(row.value as? String, status, "\(id) row: \(describe(row))", file: file, line: line)
        for text in texts {
            XCTAssertTrue(row.label.contains(text), "\(id) row doesn't read \"\(text)\": \(describe(row))", file: file, line: line)
        }
    }
}
