import AppKit
import Carbon.HIToolbox
import ImageIO
import XCTest

class LunettaUITestCase: XCTestCase {
    enum Hotkey: String, CaseIterable {
        case area = "area ⇧⌘2"
        case window = "window ⌃⇧⌘2"
        case fullScreen = "full screen ⇧⌘1"
        case text = "text ⌥⇧⌘2"
        case recordArea = "record area ⌥⇧⌘5"
        case recordWindow = "record window ⌃⌥⇧⌘5"
        case recordScreen = "record screen ⌥⇧⌘6"

        var shortcut: (name: String, key: Int, carbonModifiers: Int, flags: CGEventFlags) {
            switch self {
            case .area: ("captureArea", kVK_ANSI_2, cmdKey | shiftKey, [.maskCommand, .maskShift])
            case .window: ("captureWindow", kVK_ANSI_2, controlKey | cmdKey | shiftKey, [.maskControl, .maskCommand, .maskShift])
            case .fullScreen: ("captureFullScreen", kVK_ANSI_1, cmdKey | shiftKey, [.maskCommand, .maskShift])
            case .text: ("captureText", kVK_ANSI_2, optionKey | cmdKey | shiftKey, [.maskAlternate, .maskCommand, .maskShift])
            case .recordArea: ("recordArea", kVK_ANSI_5, optionKey | cmdKey | shiftKey, [.maskAlternate, .maskCommand, .maskShift])
            case .recordWindow: ("recordWindow", kVK_ANSI_5, controlKey | optionKey | cmdKey | shiftKey, [.maskControl, .maskAlternate, .maskCommand, .maskShift])
            case .recordScreen: ("recordScreen", kVK_ANSI_6, optionKey | cmdKey | shiftKey, [.maskAlternate, .maskCommand, .maskShift])
            }
        }
    }

    static let lunettaBundleID = "com.joaopcm.lunetta"
    /// A PNG lands 53 ms after the hotkey (spike run 45262298278). The slowest other wait this covers in run 45499134237
    /// was the Save As panel at 3.1 s; overlays, Finder windows and the editor all showed up faster.
    static let captureTimeout: TimeInterval = 10
    /// 40 times the 53 ms a capture takes to land (run 45262298278), so a stray capture is on disk before the count is checked.
    static let noFileWait: TimeInterval = 2
    /// Lunetta quit within 1.03 s of every terminate in run 45499134237.
    static let terminateTimeout: TimeInterval = 5
    /// Unchanged pixels match exactly between two captures: max channel delta 0 over 40080 pixels in run 45505547400.
    static let pixelTolerance: UInt8 = 8

    /// Subclasses add `-key value` pairs to start Lunetta with other settings.
    var extraLaunchArguments: [String] { [] }
    var overlayCorner: String { "bottomRight" }
    var showsMagnifier: Bool { false }
    var pickerPromptExplained: Bool { true }
    var extraLaunchEnvironment: [String: String] { [:] }
    var pinnedHotkeys: [Hotkey] { Hotkey.allCases }
    /// The recording stage saves its choices to Lunetta's real defaults; pinning them off keeps a panel test that
    /// failed before cleaning up from turning on, say, Show Pressed Keys for every test after it (run 45816994479).
    var pinsRecordingChoices: Bool { true }

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
                the UI test runner can't post key and mouse events (kTCCServicePostEvent), so no hotkey would reach Lunetta. \
                CI grants it with scripts/ci-grant-tcc.sh. locally, allow LunettaUITests-Runner in \
                System Settings > Privacy & Security > Accessibility and run again
                """)
            return
        }
        try terminateRunningLunettas()
        saveFolder = FileManager.default.temporaryDirectory.appending(path: "LunettaUITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: saveFolder, withIntermediateDirectories: true)
        // XCTest runs setUp and tests on the main thread; XCUIApplication is main-actor isolated.
        MainActor.assumeIsolated { launchLunetta() }
    }

    @MainActor private func launchLunetta() {
        app = XCUIApplication()
        finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        app.launchArguments = [
            "-saveFolderPath", saveFolder.path,
            "-copyToClipboardAfterCapture", "NO",
            "-overlayAutoDismiss", "NO",
            "-overlayCorner", overlayCorner,
            "-thumbnailWidth", "240",
            "-showMagnifierWhileSelecting", showsMagnifier ? "YES" : "NO",
            "-playSoundOnCapture", "NO",
            "-recordingSounds", "NO",
        ] + (pickerPromptExplained ? ["-pickerPromptExplained", "YES"] : []) + defaultShortcutArguments + recordingChoiceArguments + extraLaunchArguments
        app.launchEnvironment = extraLaunchEnvironment
        app.launch()
        finder.activate()
        let previews = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Preview")
        XCTAssertTrue(previews.isEmpty, "Preview is running (pid \(previews.map(\.processIdentifier))) and can cover what the test captures. Quit it")
        let strays = finder.windows.matching(NSPredicate(format: "title BEGINSWITH 'LunettaUITests-'"))
        XCTAssertEqual(strays.count, 0, "Finder still shows \(strays.allElementsBoundByIndex.map(\.title)) from an earlier test")
    }

    /// The installed Lunetta shares the `com.joaopcm.lunetta` defaults, so a rebound shortcut there would make every hotkey miss.
    /// The argument domain wins over those defaults; the quotes keep the JSON a plist string.
    private var defaultShortcutArguments: [String] {
        pinnedHotkeys.flatMap { hotkey in
            let shortcut = hotkey.shortcut
            return ["-KeyboardShortcuts_\(shortcut.name)", #""{\"carbonKeyCode\":\#(shortcut.key),\"carbonModifiers\":\#(shortcut.carbonModifiers)}""#]
        }
    }

    /// A key the subclass already passes is left to it.
    private var recordingChoiceArguments: [String] {
        guard pinsRecordingChoices else { return [] }
        let off: KeyValuePairs<String, String> = [
            "recordSystemAudio": "NO", "recordMicrophone": "NO", "recordingInputID": "", "showPressedKeys": "NO",
            "showMouseClicks": "NO",
        ]
        return off.filter { !extraLaunchArguments.contains("-\($0.key)") }.flatMap { ["-\($0.key)", $0.value] }
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
        postKey(hotkey.shortcut.key, flags: hotkey.shortcut.flags)
    }

    /// Settings reopens on the last tab, and an earlier test leaves it on Upload (run 45524565702).
    @MainActor func openSettingsTab(_ title: String) {
        let statusItem = app.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: Self.captureTimeout), "Lunetta's menu bar icon is missing")
        statusItem.click()
        statusItem.descendants(matching: .menuItem)["Settings…"].click()
        let tab = app.buttons.matching(NSPredicate(format: "title == %@ OR label == %@", title, title)).firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: Self.captureTimeout), "Settings has no \(title) tab")
        tab.click()
    }

    @MainActor func pressEscape() {
        postKey(kVK_Escape)
    }

    func postKey(_ key: Int, flags: CGEventFlags = []) {
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: isDown)!
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
        // A keyboard lets go of its modifiers too. Without this, every mouse event after ⌥⇧⌘6 still carried ⇧, and a
        // plain drag on the stage kept the area's aspect ratio: 260 × 194 instead of 260 × 190 (run 45872128791).
        guard !flags.isEmpty, let release = CGEvent(source: nil) else { return }
        release.type = .flagsChanged
        release.flags = []
        release.post(tap: .cghidEventTap)
    }

    /// A point in global screen coordinates (top-left origin), reached through Finder so XCUITest never activates Lunetta.
    @MainActor func screenPoint(_ point: CGPoint) -> XCUICoordinate {
        finder.menuBars.firstMatch.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x, dy: point.y))
    }

    @MainActor func center(of element: XCUIElement) -> XCUICoordinate {
        let frame = settledFrame(of: element)
        return screenPoint(CGPoint(x: frame.midX, y: frame.midY))
    }

    /// A new quick-access card slides in for 250 ms (#92); read a frame once two reads 100 ms apart agree.
    @MainActor func settledFrame(of element: XCUIElement) -> CGRect {
        var previous = element.frame
        let deadline = Date().addingTimeInterval(Self.captureTimeout)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            let current = element.frame
            if current == previous { return current }
            previous = current
        }
        return previous
    }

    @discardableResult
    @MainActor func waitForPNGs(count: Int, after hotkey: Hotkey?, file: StaticString = #filePath, line: UInt = #line) -> [URL] {
        let deadline = Date().addingTimeInterval(Self.captureTimeout)
        var found = pngs()
        while found.count < count, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            found = pngs()
        }
        guard found.count == count else {
            XCTFail(
                """
                expected exactly \(count) PNG(s) in \(saveFolder.path) within \(Self.captureTimeout) s \
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

    /// Share of pixels whose RGB differs by more than `tolerance` on any channel; 1 when the sizes differ.
    /// `regionOfB` compares `a` with that pixel rect of `b` (top-left origin).
    func differingPixelShare(_ a: URL, _ b: URL, regionOfB: CGRect? = nil, tolerance: UInt8 = LunettaUITestCase.pixelTolerance) -> Double {
        guard let first = rgba(of: a), let second = rgba(of: b, region: regionOfB), first.count == second.count, !first.isEmpty else { return 1 }
        var differing = 0
        for pixel in stride(from: 0, to: first.count, by: 4) {
            let channels = (0..<3).map { abs(Int(first[pixel + $0]) - Int(second[pixel + $0])) }
            if channels.contains(where: { $0 > Int(tolerance) }) { differing += 1 }
        }
        return Double(differing) / Double(first.count / 4)
    }

    func rgba(of url: URL, region: CGRect? = nil) -> [UInt8]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let full = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let image = region.map({ full.cropping(to: $0) }) ?? full
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

    /// `ui-macos` keeps screen recordings only for failing tests (#83), so a passing visual check keeps a screenshot instead.
    @MainActor func keepScreenshot(named name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor func assertFinderFrontmost(file: StaticString = #filePath, line: UInt = #line) {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        XCTAssertEqual(front, "com.apple.finder", "Finder lost focus to \(front ?? "nothing")", file: file, line: line)
    }

    @MainActor var loupe: XCUIElement {
        app.descendants(matching: .any).matching(identifier: AccessibilityID.loupe).firstMatch
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
        XCTFail("no overlay after \(hotkey.rawValue). \(dialogDescription()) Lunetta's accessibility tree:\n\(app.debugDescription)", file: file, line: line)
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
        // Quit Lunetta first: an overlay left up by a failed test holds key focus and would swallow the ⌘W.
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
        guard dialog.exists else { return "No Lunetta dialog is on screen. \(front)" }
        let texts = dialog.staticTexts.allElementsBoundByIndex.compactMap { $0.value as? String }
        return "Lunetta shows a dialog: \(texts). \(front)"
    }

    struct LunettaStillRunning: Error, CustomStringConvertible {
        let description: String
    }

    private func terminateRunningLunettas() throws {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: Self.lunettaBundleID)
        running.forEach { $0.terminate() }
        let stubborn = waitForTermination(of: running)
        stubborn.forEach { $0.forceTerminate() }
        let survivors = waitForTermination(of: stubborn)
        guard survivors.isEmpty else {
            let list = survivors.map { "pid \($0.processIdentifier) at \($0.bundleURL?.path ?? "unknown path")" }.joined(separator: ", ")
            throw LunettaStillRunning(description: "Lunetta survived terminate and forceTerminate, \(Self.terminateTimeout) s each: \(list)")
        }
    }

    private func waitForTermination(of apps: [NSRunningApplication]) -> [NSRunningApplication] {
        let deadline = Date().addingTimeInterval(Self.terminateTimeout)
        while apps.contains(where: { !$0.isTerminated }), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return apps.filter { !$0.isTerminated }
    }
}
