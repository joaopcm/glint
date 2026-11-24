import AppKit
import Carbon.HIToolbox
import ImageIO
import XCTest

class GlintUITestCase: XCTestCase {
    enum Hotkey: String {
        case area = "area ⇧⌘2"
        case window = "window ⌃⇧⌘2"
        case fullScreen = "full screen ⇧⌘1"
        case text = "text ⌥⇧⌘2"
    }

    static let glintBundleID = "com.joaopcm.glint"
    /// Spike run 45262298278 measured 53 ms from the Screen Recording grant to the PNG on disk.
    static let captureTimeout: TimeInterval = 10
    static let noFileWait: TimeInterval = 2
    static let terminateTimeout: TimeInterval = 5

    /// Subclasses add `-key value` pairs to start Glint with other settings.
    var extraLaunchArguments: [String] { [] }

    @MainActor private(set) var app: XCUIApplication!
    @MainActor private(set) var finder: XCUIApplication!
    private(set) var saveFolder: URL!

    @MainActor var overlay: XCUIElement {
        overlays.firstMatch
    }

    @MainActor var pointerScreen: NSScreen {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.screens[0]
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard CGPreflightPostEventAccess() else {
            _ = CGRequestPostEventAccess()
            XCTFail("""
                the UI test runner can't post key and mouse events (kTCCServicePostEvent), so no hotkey would reach Glint. \
                CI grants it with scripts/ci-grant-tcc.sh. locally, allow GlintUITests-Runner in \
                System Settings > Privacy & Security > Accessibility and run again
                """)
            return
        }
        try terminateRunningGlints()
        saveFolder = FileManager.default.temporaryDirectory.appending(path: "GlintUITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: saveFolder, withIntermediateDirectories: true)
        // XCTest runs setUp and tests on the main thread; XCUIApplication is main-actor isolated.
        MainActor.assumeIsolated { launchGlint() }
    }

    @MainActor private func launchGlint() {
        app = XCUIApplication()
        finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        app.launchArguments = [
            "-saveFolderPath", saveFolder.path,
            "-copyToClipboardAfterCapture", "NO",
            "-overlayAutoDismiss", "NO",
            "-overlayCorner", "bottomRight",
            "-thumbnailWidth", "240",
        ] + extraLaunchArguments
        app.launch()
        finder.activate()
        XCTAssertFalse(overlay.exists, "a selection overlay is already up before the test started")
    }

    override func tearDownWithError() throws {
        MainActor.assumeIsolated { app?.terminate() }
        if let saveFolder {
            try? FileManager.default.removeItem(at: saveFolder)
        }
    }

    /// Keys go through the HID event tap like a real keyboard. XCUITest's `typeKey` activates the element's app first,
    /// which a user's keypress never does, and it stalls while the non-activating overlay holds key focus (run 45284501150).
    @MainActor func press(_ hotkey: Hotkey) {
        switch hotkey {
        case .area: postKey(kVK_ANSI_2, flags: [.maskCommand, .maskShift])
        case .window: postKey(kVK_ANSI_2, flags: [.maskControl, .maskCommand, .maskShift])
        case .fullScreen: postKey(kVK_ANSI_1, flags: [.maskCommand, .maskShift])
        case .text: postKey(kVK_ANSI_2, flags: [.maskAlternate, .maskCommand, .maskShift])
        }
    }

    @MainActor func pressEscape() {
        postKey(kVK_Escape)
    }

    private func postKey(_ key: Int, flags: CGEventFlags = []) {
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: isDown)!
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }

    /// A point in global screen coordinates (top-left origin), reached through Finder so XCUITest never activates Glint.
    @MainActor func screenPoint(_ point: CGPoint) -> XCUICoordinate {
        finder.menuBars.firstMatch.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x, dy: point.y))
    }

    @MainActor func center(of element: XCUIElement) -> XCUICoordinate {
        let frame = element.frame
        return screenPoint(CGPoint(x: frame.midX, y: frame.midY))
    }

    @discardableResult
    @MainActor func waitForPNGs(count: Int, after hotkey: Hotkey?, file: StaticString = #filePath, line: UInt = #line) -> [URL] {
        let deadline = Date().addingTimeInterval(Self.captureTimeout)
        var found = pngs()
        while found.count < count, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            found = pngs()
        }
        guard found.count >= count else {
            XCTFail(
                """
                expected \(count) PNG(s) in \(saveFolder.path) within \(Self.captureTimeout) s \
                after \(hotkey?.rawValue ?? "the last action"), found \(found.map(\.lastPathComponent)). \
                \(dialogDescription())
                """,
                file: file, line: line
            )
            return found
        }
        return found
    }

    /// Waits long enough for a stray capture to land (53 ms measured in run 45262298278), then checks the exact count.
    @MainActor func assertPNGCount(_ expected: Int, file: StaticString = #filePath, line: UInt = #line) {
        RunLoop.current.run(until: Date().addingTimeInterval(Self.noFileWait))
        let found = pngs()
        XCTAssertEqual(found.count, expected, "expected exactly \(expected) PNG(s), found \(found.map(\.lastPathComponent))", file: file, line: line)
    }

    /// Window captures keep the shadow on a transparent background; a full-screen capture has no transparent corner.
    func topLeftAlpha(of url: URL) -> UInt8? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let corner = image.cropping(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(corner, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return pixel[3]
    }

    /// Share of the PNG's pixels whose RGB satisfies `matches`; 0 when the PNG can't be read.
    func pixelShare(of url: URL, where matches: (_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Bool) -> Double {
        guard let pixels = rgba(of: url), !pixels.isEmpty else { return 0 }
        let hits = stride(from: 0, to: pixels.count, by: 4).filter { matches(pixels[$0], pixels[$0 + 1], pixels[$0 + 2]) }.count
        return Double(hits) / Double(pixels.count / 4)
    }

    func rgba(of url: URL) -> [UInt8]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixels
    }

    func pixelSize(of url: URL) -> CGSize {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return .zero }
        return CGSize(width: width, height: height)
    }

    @MainActor func assertFinderFrontmost(file: StaticString = #filePath, line: UInt = #line) {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        XCTAssertEqual(front, "com.apple.finder", "Finder lost focus to \(front ?? "nothing")", file: file, line: line)
    }

    @MainActor var overlays: XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: AccessibilityID.selectionOverlay)
    }

    @MainActor func point(onOverlayAt offset: CGVector) -> XCUICoordinate {
        let origin = overlay.frame.origin
        return screenPoint(CGPoint(x: origin.x + offset.dx, y: origin.y + offset.dy))
    }

    @MainActor func waitForOverlay(after hotkey: Hotkey, file: StaticString = #filePath, line: UInt = #line) {
        guard !overlay.waitForExistence(timeout: Self.captureTimeout) else { return }
        XCTFail("no overlay after \(hotkey.rawValue). \(dialogDescription()) Glint's accessibility tree:\n\(app.debugDescription)", file: file, line: line)
    }

    @MainActor func assertOverlayClosed(after hotkey: Hotkey, file: StaticString = #filePath, line: UInt = #line) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: overlay)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: Self.captureTimeout), .completed,
                       "the overlay from \(hotkey.rawValue) did not close", file: file, line: line)
    }

    @MainActor func openFinderWindow() -> XCUIElement {
        NSWorkspace.shared.open(saveFolder)
        let window = finder.windows[saveFolder.lastPathComponent]
        XCTAssertTrue(window.waitForExistence(timeout: Self.captureTimeout), "Finder did not open \(saveFolder.path)")
        // Quit Glint first: an overlay left up by a failed test holds key focus and would swallow the ⌘W.
        addTeardownBlock { @MainActor in
            self.app.terminate()
            window.typeKey("w", modifierFlags: .command)
        }
        return window
    }

    private func pngs() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: saveFolder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "png" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    @MainActor private func dialogDescription() -> String {
        let dialog = app.dialogs.firstMatch
        let front = "Frontmost app: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none")."
        guard dialog.exists else { return "No Glint dialog is on screen. \(front)" }
        let texts = dialog.staticTexts.allElementsBoundByIndex.compactMap { $0.value as? String }
        return "Glint shows a dialog: \(texts). \(front)"
    }

    private func terminateRunningGlints() throws {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: Self.glintBundleID)
        running.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(Self.terminateTimeout)
        while running.contains(where: { !$0.isTerminated }), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        running.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
    }
}
