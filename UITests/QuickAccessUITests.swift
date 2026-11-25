import AppKit
import ImageIO
import XCTest

final class QuickAccessUITests: LunettaUITestCase {
    /// `ThumbnailPresenter` folds the column back 1 s after the pointer leaves it.
    static let foldBackTimeout: TimeInterval = 5
    /// With no card in the capture, 0 of the 40080 card-region pixels changed (run 45505547400); a card changes nearly all of them.
    static let cardsInCaptureThreshold = 0.01

    @MainActor func testOneThumbnailPerSavedCaptureNoneAfterCancel() {
        press(.fullScreen)
        waitForPNGs(count: 1, after: .fullScreen)
        press(.area)
        waitForOverlay(after: .area)
        point(onOverlayAt: CGVector(dx: 100, dy: 100)).press(forDuration: 0.1, thenDragTo: point(onOverlayAt: CGVector(dx: 200, dy: 200)))
        waitForPNGs(count: 2, after: .area)
        let window = openFinderWindow()
        press(.window)
        waitForOverlay(after: .window)
        let center = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.hover()
        center.click()
        let pngs = waitForPNGs(count: 3, after: .window)
        for png in pngs {
            XCTAssertTrue(card(for: png).waitForExistence(timeout: Self.captureTimeout), "no thumbnail for \(png.lastPathComponent)")
        }

        press(.area)
        waitForOverlay(after: .area)
        pressEscape()
        assertOverlayClosed(after: .area)
        assertPNGCount(3)
        XCTAssertEqual(cards.count, 3, "a cancelled capture added a thumbnail")
    }

    @MainActor func testHoverShowsToolbarAndHidesIt() {
        let card = captureOneCard()
        center(of: card).hover()
        for label in ["Copy", "Save As…", "Annotate", "Pin to Screen", "Close"] {
            let button = app.buttons[label].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: Self.captureTimeout), "hovering shows no \"\(label)\" button")
            XCTAssertTrue(button.isHittable, "\"\(label)\" is not clickable while hovered")
        }
        moveAwayFromCards()
        XCTAssertTrue(waitUntil(app.buttons["Copy"].firstMatch, matches: "exists == false OR isHittable == false"),
                      "the toolbar stayed after the pointer left")
    }

    /// Finder stays frontmost: the labels have to show while Lunetta is in the background (#91).
    @MainActor func testHoveringAnActionShowsItsLabelWhileAnotherAppIsFrontmost() {
        let card = captureOneCard()
        center(of: card).hover()
        let label = app.descendants(matching: .any).matching(identifier: AccessibilityID.cardActionLabel).firstMatch
        for name in ["Copy", "Save As…", "Pin to Screen"] {
            center(of: app.buttons[name].firstMatch).hover()
            XCTAssertTrue(waitUntil(label, matches: "value == '\(name)'"), "hovering \"\(name)\" showed \(label.exists ? "\"\(label.value ?? "")\"" : "no label")")
        }
        keepScreenshot(named: "hovered Pin to Screen with its label")
        assertFinderFrontmost()
        moveAwayFromCards()
        XCTAssertTrue(waitUntil(label, matches: "exists == false"), "the label stayed after the pointer left the card")
    }

    @MainActor func testCopyPutsFileOnPasteboardAndClosesCard() {
        let (card, png) = captureOneCardAndFile()
        center(of: card).hover()
        center(of: app.buttons["Copy"].firstMatch).click()
        XCTAssertTrue(waitUntilGone(card), "Copy left the card on screen")
        XCTAssertEqual(NSPasteboard.general.string(forType: .fileURL), png.absoluteString)
        XCTAssertNotNil(NSPasteboard.general.data(forType: .png), "Copy put no PNG on the pasteboard")
    }

    @MainActor func testSaveAsWritesChosenFileAndCancelKeepsCard() throws {
        let (card, png) = captureOneCardAndFile()
        center(of: card).hover()
        center(of: app.buttons["Save As…"].firstMatch).click()
        _ = savePanelSaveButton()
        app.typeKey("a", modifierFlags: .command)
        app.typeText("renamed")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitUntilGone(card), "Save As left the card on screen")
        XCTAssertTrue(FileManager.default.fileExists(atPath: saveFolder.appending(path: "renamed.png").path), "Save As wrote no renamed.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: png.path), "Save As removed the original")
        assertFinderFrontmost()

        let (second, _) = captureOneCardAndFile(expectedTotal: 3)
        center(of: second).hover()
        center(of: app.buttons["Save As…"].firstMatch).click()
        _ = savePanelSaveButton()
        pressEscape()
        assertPNGCount(3)
        XCTAssertTrue(second.exists, "cancelling Save As closed the card")
        assertFinderFrontmost()
    }

    @MainActor func testAnnotateDrawsRectangleAndSavesOverCapture() throws {
        let (card, png) = captureOneCardAndFile()
        let original = saveFolder.appending(path: "original.bak")
        try FileManager.default.copyItem(at: png, to: original)
        drawRectangleAndSave(from: card, png: png)

        let size = pixelSize(of: png)
        let around = CGRect(x: size.width * 0.28, y: size.height * 0.28, width: size.width * 0.34, height: size.height * 0.34).integral
        let away = CGRect(x: 0, y: 0, width: size.width * 0.2, height: size.height * 0.2).integral
        XCTAssertGreaterThan(changedShare(original, png, in: around), 0.005, "the saved PNG has no rectangle where it was drawn")
        XCTAssertEqual(changedShare(original, png, in: away), 0, "Save changed pixels away from the rectangle")
        XCTAssertTrue(card.exists, "annotating closed the card")
        assertPNGCount(1)
    }

    @MainActor func testReannotatingFromTheSameCardKeepsTheRectangleSelectable() {
        let (card, png) = captureOneCardAndFile()
        drawRectangleAndSave(from: card, png: png)

        openEditor(from: card)
        XCTAssertTrue(waitUntil(editorCanvas, matches: "value BEGINSWITH '1 annotation,'"),
                      "reopening showed \(editorCanvas.value ?? "nothing"), not the saved rectangle")
        tool("Select").click()
        imagePoint(0.45, png: png).click()
        XCTAssertTrue(waitUntil(editorCanvas, matches: "value == '1 annotation, Rectangle selected'"),
                      "clicking the rectangle left the canvas at \(editorCanvas.value ?? "nothing")")
    }

    @MainActor func testPinOpensFloatingWindowThatCloses() {
        let (card, png) = captureOneCardAndFile()
        center(of: card).hover()
        center(of: app.buttons["Pin to Screen"].firstMatch).click()
        let pinned = app.windows[png.lastPathComponent]
        XCTAssertTrue(pinned.waitForExistence(timeout: Self.captureTimeout), "Pin opened no window")
        XCTAssertTrue(waitUntilGone(card), "Pin left the card on screen")
        center(of: pinned.buttons[XCUIIdentifierCloseWindow]).click()
        XCTAssertTrue(waitUntilGone(pinned), "the pinned window did not close")
    }

    @MainActor func testCloseRemovesCardKeepsFile() {
        let (card, png) = captureOneCardAndFile()
        center(of: card).hover()
        center(of: app.buttons["Close"].firstMatch).click()
        XCTAssertTrue(waitUntilGone(card), "Close left the card on screen")
        XCTAssertTrue(FileManager.default.fileExists(atPath: png.path), "Close deleted the PNG")
    }

    @MainActor func testPileShowsCountExpandsAndFoldsBack() {
        moveAwayFromCards()
        for count in 1...3 {
            press(.fullScreen)
            waitForPNGs(count: count, after: .fullScreen)
        }
        XCTAssertTrue(waitUntil(cards, count: 3), "expected 3 cards, found \(cards.count)")
        XCTAssertLessThanOrEqual(cardSpread(), 2 * ThumbnailPile.offset, "three captures did not pile up")

        let top = cards.allElementsBoundByIndex.max { $0.frame.minY < $1.frame.minY }!
        center(of: top).click()
        XCTAssertTrue(waitUntil { self.cardSpread() > 2 * ThumbnailPile.offset }, "clicking the pile did not expand it")

        moveAwayFromCards()
        XCTAssertTrue(waitUntil(timeout: Self.foldBackTimeout) { self.cardSpread() <= 2 * ThumbnailPile.offset },
                      "the column did not fold back within \(Self.foldBackTimeout) s")
    }

    @MainActor func testThumbnailsNeverInCaptures() throws {
        moveAwayFromCards()
        press(.fullScreen)
        let withoutCards = waitForPNGs(count: 1, after: .fullScreen)[0]
        press(.fullScreen)
        let before = waitForPNGs(count: 2, after: .fullScreen)
        XCTAssertTrue(waitUntil(cards, count: 2), "expected 2 cards, found \(cards.count)")
        let cardFrames = cards.allElementsBoundByIndex.map { settledFrame(of: $0) }
        press(.fullScreen)
        let withCards = try XCTUnwrap(waitForPNGs(count: 3, after: .fullScreen).first { !before.contains($0) })

        let region = cardFrames.reduce(CGRect.null) { $0.union($1) }
        let changed = try changedFraction(withoutCards, withCards, in: region)
        XCTAssertLessThan(changed, Self.cardsInCaptureThreshold, "\(Int(changed * 100))% of the thumbnail area differs: the cards are in the capture")

        press(.window)
        waitForOverlay(after: .window)
        let onCard = point(onOverlayAt: CGVector(dx: region.midX - overlay.frame.minX, dy: region.midY - overlay.frame.minY))
        onCard.hover()
        onCard.click()
        assertPNGCount(3)
        pressEscape()
        assertOverlayClosed(after: .window)
    }

    @MainActor private func openEditor(from card: XCUIElement) {
        center(of: card).hover()
        center(of: app.buttons["Annotate"].firstMatch).click()
        XCTAssertTrue(editorCanvas.waitForExistence(timeout: Self.captureTimeout), "Annotate opened no editor")
    }

    @MainActor private func drawRectangleAndSave(from card: XCUIElement, png: URL) {
        openEditor(from: card)
        tool("Rectangle").click()
        imagePoint(0.3, png: png).press(forDuration: 0.1, thenDragTo: imagePoint(0.6, png: png))
        center(of: app.buttons["Save"].firstMatch).click()
        XCTAssertTrue(waitUntilGone(editorCanvas), "Save left the editor open")
    }

    /// Tool buttons are on/off toggles, which accessibility reports as checkboxes, not buttons (run 45495161930).
    @MainActor private func tool(_ label: String) -> XCUICoordinate {
        center(of: app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch)
    }

    @MainActor private func imagePoint(_ fraction: CGFloat, png: URL) -> XCUICoordinate {
        let image = aspectFit(pixelSize(of: png), in: editorCanvas.frame)
        return screenPoint(CGPoint(x: image.minX + image.width * fraction, y: image.minY + image.height * fraction))
    }

    @MainActor private var editorCanvas: XCUIElement {
        app.descendants(matching: .any).matching(identifier: AccessibilityID.editorCanvas).firstMatch
    }

    private func aspectFit(_ size: CGSize, in frame: CGRect) -> CGRect {
        let scale = min(frame.width / size.width, frame.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: frame.midX - fitted.width / 2, y: frame.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
    }

    private func changedShare(_ a: URL, _ b: URL, in region: CGRect) -> Double {
        guard let first = rgba(of: a, region: region), let second = rgba(of: b, region: region), first.count == second.count, !first.isEmpty else { return 1 }
        let changed = stride(from: 0, to: first.count, by: 4).filter { pixel in
            (0..<3).contains { abs(Int(first[pixel + $0]) - Int(second[pixel + $0])) > Int(Self.pixelTolerance) }
        }.count
        return Double(changed) / Double(first.count / 4)
    }

    @MainActor private var cards: XCUIElementQuery {
        app.images.matching(NSPredicate(format: "label BEGINSWITH %@", "Screenshot Lunetta "))
    }

    @MainActor private func card(for png: URL) -> XCUIElement {
        app.images["Screenshot \(png.lastPathComponent)"]
    }

    @MainActor private func captureOneCard() -> XCUIElement {
        captureOneCardAndFile().card
    }

    @MainActor private func captureOneCardAndFile(expectedTotal: Int = 1) -> (card: XCUIElement, png: URL) {
        press(.fullScreen)
        let pngs = waitForPNGs(count: expectedTotal, after: .fullScreen)
        let newest = pngs.max { created($0) < created($1) }!
        let card = card(for: newest)
        XCTAssertTrue(card.waitForExistence(timeout: Self.captureTimeout), "no thumbnail for \(newest.lastPathComponent)")
        return (card, newest)
    }

    private func created(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }

    @MainActor private func moveAwayFromCards() {
        finder.menuBars.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
    }

    @MainActor private func savePanelSaveButton() -> XCUIElement {
        let save = app.buttons.matching(NSPredicate(format: "label == 'Save' OR title == 'Save'")).firstMatch
        if !save.waitForExistence(timeout: Self.captureTimeout) {
            XCTFail("Save As showed no save panel. Lunetta's accessibility tree:\n\(app.debugDescription)")
        }
        return save
    }

    @MainActor private func cardSpread() -> CGFloat {
        let tops = cards.allElementsBoundByIndex.map(\.frame.minY)
        guard let low = tops.min(), let high = tops.max() else { return 0 }
        return high - low
    }

    @MainActor private func waitUntil(timeout: TimeInterval = LunettaUITestCase.captureTimeout, _ condition: @escaping () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return true
    }

    @MainActor private func waitUntil(_ query: XCUIElementQuery, count: Int) -> Bool {
        waitUntil { query.count == count }
    }

    @MainActor private func waitUntil(_ element: XCUIElement, matches predicate: String) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: Self.captureTimeout) == .completed
    }

    @MainActor private func waitUntilGone(_ element: XCUIElement) -> Bool {
        waitUntil(element, matches: "exists == false")
    }

    /// Fraction of pixels in `region` (global points, top-left origin) whose color differs between two captures of the same display.
    @MainActor private func changedFraction(_ a: URL, _ b: URL, in region: CGRect) throws -> Double {
        let first = try rgba(a), second = try rgba(b)
        XCTAssertEqual(first.width, second.width)
        let screen = pointerScreen
        let scale = CGFloat(first.width) / screen.frame.width
        let screenTop = NSScreen.screens[0].frame.maxY - screen.frame.maxY
        let pixels = CGRect(x: (region.minX - screen.frame.minX) * scale, y: (region.minY - screenTop) * scale,
                            width: region.width * scale, height: region.height * scale)
            .integral.intersection(CGRect(x: 0, y: 0, width: first.width, height: first.height))
        var changed = 0, total = 0, maxDelta = 0
        for y in Int(pixels.minY)..<Int(pixels.maxY) {
            for x in Int(pixels.minX)..<Int(pixels.maxX) {
                let i = y * first.width * 4 + x * 4
                let delta = (0..<3).map { abs(Int(first.bytes[i + $0]) - Int(second.bytes[i + $0])) }.max()!
                maxDelta = max(maxDelta, delta)
                changed += delta > Int(Self.pixelTolerance) ? 1 : 0
                total += 1
            }
        }
        let fraction = total == 0 ? 1 : Double(changed) / Double(total)
        XCTContext.runActivity(named: "card region: \(fraction) of \(total) pixels changed, max channel delta \(maxDelta)") { _ in }
        return fraction
    }

    private func rgba(_ url: URL) throws -> (bytes: [UInt8], width: Int, height: Int) {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (bytes, image.width, image.height)
    }
}
