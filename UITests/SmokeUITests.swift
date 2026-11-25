import AppKit
import XCTest

final class SmokeUITests: LunettaUITestCase {
    @MainActor func testFullScreenHotkeyWritesDisplaySizedPNGAndKeepsFinderFrontmost() {
        let screen = pointerScreen
        press(.fullScreen)
        let png = waitForPNGs(count: 1, after: .fullScreen)[0]
        XCTAssertNotNil(
            png.lastPathComponent.range(of: #"^Lunetta \d{4}-\d{2}-\d{2} at \d{2}\.\d{2}\.\d{2}\.png$"#, options: .regularExpression),
            "unexpected file name \(png.lastPathComponent)"
        )
        XCTAssertEqual(pixelSize(of: png), CGSize(
            width: screen.frame.width * screen.backingScaleFactor,
            height: screen.frame.height * screen.backingScaleFactor
        ))
        XCTAssertTrue(
            app.images["Screenshot \(png.lastPathComponent)"].waitForExistence(timeout: Self.captureTimeout),
            "no thumbnail for \(png.lastPathComponent)"
        )
        assertFinderFrontmost()
    }

    @MainActor func testSaveFolderIsTheTempFolder() throws {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let before = try FileManager.default.contentsOfDirectory(atPath: desktop.path).count
        press(.fullScreen)
        let png = waitForPNGs(count: 1, after: .fullScreen)[0]
        XCTAssertEqual(png.deletingLastPathComponent().standardizedFileURL, saveFolder.standardizedFileURL)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: desktop.path).count, before)
    }

    @MainActor func testSetUpLeavesOneLunettaRunning() {
        XCTAssertEqual(NSRunningApplication.runningApplications(withBundleIdentifier: Self.lunettaBundleID).count, 1)
    }
}
