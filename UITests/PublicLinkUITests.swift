import AppKit
import XCTest

final class PublicLinkUITests: GlintUITestCase {
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
            "GLINT_UI_TEST_ACCESS_KEY_ID": "AKIAIOSFODNN7EXAMPLE",
            "GLINT_UI_TEST_SECRET_ACCESS_KEY": "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        ]
    }

    override func setUpWithError() throws {
        server = try StubS3Server()
        try super.setUpWithError()
    }

    override func tearDownWithError() throws {
        try super.tearDownWithError()
        server?.stop()
    }

    @MainActor func testTestConnectionSaysCopiedLinksWontOpenOnAPrivateBucket() {
        let statusItem = app.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: Self.captureTimeout), "Glint's menu bar icon is missing")
        statusItem.click()
        statusItem.descendants(matching: .menuItem)["Settings…"].click()
        // The Settings toolbar tab is a button titled "Upload" whose label is sometimes empty (ui.xcresult of run 45478719380).
        let uploadTab = app.buttons.matching(NSPredicate(format: "title == %@ OR label == %@", "Upload", "Upload")).firstMatch
        XCTAssertTrue(uploadTab.waitForExistence(timeout: Self.captureTimeout), "Settings has no Upload tab")
        uploadTab.click()

        let testConnection = app.descendants(matching: .any).matching(identifier: AccessibilityID.testConnection).firstMatch
        XCTAssertTrue(testConnection.waitForExistence(timeout: Self.captureTimeout), "the Upload tab has no Test Connection button")
        scrollIntoView(testConnection)
        testConnection.click()

        let publicLink = app.descendants(matching: .any).matching(identifier: AccessibilityID.publicLinkResult).firstMatch
        XCTAssertTrue(publicLink.waitForExistence(timeout: Self.captureTimeout), "Test Connection said nothing about the public link")
        let shown = "\(publicLink.value ?? "") \(publicLink.label)"
        XCTAssertTrue(shown.contains("Copied links won't open: the bucket isn't publicly readable (HTTP 403 AccessDenied)."), "public link reads: \(shown)")
        let hint = app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "mc anonymous set download <alias>/shots/uitest")).firstMatch
        XCTAssertTrue(hint.exists, "no MinIO hint for a non-AWS endpoint")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: AccessibilityID.makeLinksPublic).firstMatch.exists, "Make Links Public shows for a non-AWS endpoint")

        let requests = server.requests.map { "\($0.method) \($0.path) signed=\($0.headers["authorization"] != nil)" }
        XCTAssertEqual(requests.count, 3, "\(requests)")
        XCTAssertTrue(requests[1].hasPrefix("GET /shots/uitest/glint-connection-test-") && requests[1].hasSuffix("signed=false"), "\(requests)")
        XCTAssertTrue(requests[2].hasPrefix("DELETE /shots/uitest/glint-connection-test-"), "\(requests)")
    }
}
