import AppKit
import ImageIO
import XCTest

class GlintUITestCase: XCTestCase {
    enum Hotkey: String {
        case area = "area ⇧⌘2"
        case window = "window ⌃⇧⌘2"
        case fullScreen = "full screen ⇧⌘1"
    }

    static let glintBundleID = "com.joaopcm.glint"
    /// Spike run 45262298278 measured 53 ms from the Screen Recording grant to the PNG on disk.
    static let captureTimeout: TimeInterval = 10
    static let noFileWait: TimeInterval = 2
    static let terminateTimeout: TimeInterval = 5

    @MainActor private(set) var app: XCUIApplication!
    @MainActor private(set) var finder: XCUIApplication!
    private(set) var saveFolder: URL!

    @MainActor var overlay: XCUIElement {
        app.windows.matching(identifier: AccessibilityID.selectionOverlay).firstMatch
    }

    @MainActor var pointerScreen: NSScreen {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.screens[0]
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
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
        ]
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

    @MainActor func press(_ hotkey: Hotkey) {
        switch hotkey {
        case .area: finder.typeKey("2", modifierFlags: [.command, .shift])
        case .window: finder.typeKey("2", modifierFlags: [.control, .command, .shift])
        case .fullScreen: finder.typeKey("1", modifierFlags: [.command, .shift])
        }
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

    @MainActor func assertNoNewPNG(file: StaticString = #filePath, line: UInt = #line) {
        let before = pngs()
        RunLoop.current.run(until: Date().addingTimeInterval(Self.noFileWait))
        XCTAssertEqual(pngs(), before, "a PNG was written when none should be", file: file, line: line)
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

    private func pngs() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: saveFolder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "png" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    @MainActor private func dialogDescription() -> String {
        let dialog = app.dialogs.firstMatch
        guard dialog.exists else { return "No Glint dialog is on screen." }
        let texts = dialog.staticTexts.allElementsBoundByIndex.compactMap { $0.value as? String }
        return "Glint shows a dialog: \(texts)."
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
