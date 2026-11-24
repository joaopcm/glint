import AppKit
import XCTest

final class UploadUITests: GlintUITestCase {
    static let publicBaseURL = "https://shots.example.test/glint"
    private var server: StubS3Server!

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
        ["GLINT_UI_TEST_ACCESS_KEY_ID": "AKIAIOSFODNN7EXAMPLE", "GLINT_UI_TEST_SECRET_ACCESS_KEY": "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"]
    }

    override func setUpWithError() throws {
        server = try StubS3Server()
        try super.setUpWithError()
    }

    override func tearDownWithError() throws {
        try super.tearDownWithError()
        server?.stop()
    }

    @MainActor func testUploadPutsTheCaptureInlineAndCopiesItsLink() throws {
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
}
