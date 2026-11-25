import XCTest

final class WindowWallpaperUITests: GlintUITestCase {
    static let padding: CGFloat = 40

    override var extraLaunchArguments: [String] {
        ["-windowCaptureWallpaper", "YES", "-windowWallpaperPadding", "\(Int(Self.padding))"]
    }

    @MainActor func testWindowCaptureSitsOnTheWallpaperWithItsPadding() {
        let window = openFinderWindow()
        let frame = window.frame
        let scale = pointerScreen.backingScaleFactor
        press(.window)
        waitForOverlay(after: .window)
        let center = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.hover()
        center.click()
        let png = waitForPNGs(count: 1, after: .window)[0]
        let capture = XCTAttachment(contentsOfFile: png)
        capture.lifetime = .keepAlways
        add(capture)
        let size = pixelSize(of: png)
        let padding = 2 * Self.padding * scale
        XCTAssertGreaterThanOrEqual(size.width, frame.width * scale + padding, "the PNG is narrower than the window plus \(Self.padding) pt of wallpaper on each side")
        XCTAssertGreaterThanOrEqual(size.height, frame.height * scale + padding, "the PNG is shorter than the window plus \(Self.padding) pt of wallpaper on each side")
        XCTAssertEqual(topLeftAlpha(of: png), 255, "the corner is see-through: no wallpaper behind the window")
    }
}
