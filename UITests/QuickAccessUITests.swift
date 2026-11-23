import AppKit
import ImageIO
import XCTest

final class QuickAccessUITests: GlintUITestCase {
    /// `ThumbnailPresenter` folds the column back 1 s after the pointer leaves it.
    static let foldBackTimeout: TimeInterval = 5
    /// The collapsed pile offsets each card 7 pt up (`ThumbnailPresenter.frame`).
    static let pileOffset: CGFloat = 7

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
        overlay.typeKey(.escape, modifierFlags: [])
        assertOverlayClosed(after: .area)
        assertNoNewPNG()
        XCTAssertEqual(cards.count, 3, "a cancelled capture added a thumbnail")
    }

    @MainActor func testHoverShowsToolbarAndHidesIt() {
        let card = captureOneCard()
        card.hover()
        for label in ["Copy", "Save As…", "Annotate in Preview", "Pin to Screen", "Close"] {
            let button = app.buttons[label].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: Self.captureTimeout), "hovering shows no \"\(label)\" button")
            XCTAssertTrue(button.isHittable, "\"\(label)\" is not clickable while hovered")
        }
        moveAwayFromCards()
        XCTAssertTrue(waitUntil(app.buttons["Copy"].firstMatch, matches: "exists == false OR isHittable == false"),
                      "the toolbar stayed after the pointer left")
    }

    @MainActor func testCopyPutsFileOnPasteboardAndClosesCard() {
        let (card, png) = captureOneCardAndFile()
        card.hover()
        app.buttons["Copy"].firstMatch.click()
        XCTAssertTrue(waitUntilGone(card), "Copy left the card on screen")
        XCTAssertEqual(NSPasteboard.general.string(forType: .fileURL), png.absoluteString)
        XCTAssertNotNil(NSPasteboard.general.data(forType: .png), "Copy put no PNG on the pasteboard")
    }

    @MainActor func testSaveAsWritesChosenFileAndCancelKeepsCard() throws {
        let (card, png) = captureOneCardAndFile()
        card.hover()
        app.buttons["Save As…"].firstMatch.click()
        _ = savePanelSaveButton()
        app.typeKey("a", modifierFlags: .command)
        app.typeText("renamed")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitUntilGone(card), "Save As left the card on screen")
        XCTAssertTrue(FileManager.default.fileExists(atPath: saveFolder.appending(path: "renamed.png").path), "Save As wrote no renamed.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: png.path), "Save As removed the original")
        assertFinderFrontmost()

        let (second, _) = captureOneCardAndFile(expectedTotal: 3)
        second.hover()
        app.buttons["Save As…"].firstMatch.click()
        savePanelSaveButton().typeKey(.escape, modifierFlags: [])
        assertNoNewPNG()
        XCTAssertTrue(second.exists, "cancelling Save As closed the card")
        assertFinderFrontmost()
    }

    @MainActor func testAnnotateOpensPreviewAndClosesCard() {
        let preview = XCUIApplication(bundleIdentifier: "com.apple.Preview")
        addTeardownBlock { @MainActor in preview.terminate() }
        let card = captureOneCard()
        card.hover()
        app.buttons["Annotate in Preview"].firstMatch.click()
        XCTAssertTrue(preview.wait(for: .runningForeground, timeout: Self.captureTimeout), "Annotate did not open Preview")
        XCTAssertTrue(waitUntilGone(card), "Annotate left the card on screen")
    }

    @MainActor func testPinOpensFloatingWindowThatCloses() {
        let (card, png) = captureOneCardAndFile()
        card.hover()
        app.buttons["Pin to Screen"].firstMatch.click()
        let pinned = app.windows[png.lastPathComponent]
        XCTAssertTrue(pinned.waitForExistence(timeout: Self.captureTimeout), "Pin opened no window")
        XCTAssertTrue(waitUntilGone(card), "Pin left the card on screen")
        pinned.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(waitUntilGone(pinned), "the pinned window did not close")
    }

    @MainActor func testCloseRemovesCardKeepsFile() {
        let (card, png) = captureOneCardAndFile()
        card.hover()
        app.buttons["Close"].firstMatch.click()
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
        XCTAssertLessThanOrEqual(cardSpread(), 2 * Self.pileOffset, "three captures did not pile up")

        let top = cards.allElementsBoundByIndex.max { $0.frame.minY < $1.frame.minY }!
        top.click()
        XCTAssertTrue(waitUntil { self.cardSpread() > 2 * Self.pileOffset }, "clicking the pile did not expand it")

        moveAwayFromCards()
        XCTAssertTrue(waitUntil(timeout: Self.foldBackTimeout) { self.cardSpread() <= 2 * Self.pileOffset },
                      "the column did not fold back within \(Self.foldBackTimeout) s")
    }

    @MainActor func testThumbnailsNeverInCaptures() throws {
        moveAwayFromCards()
        press(.fullScreen)
        let withoutCards = waitForPNGs(count: 1, after: .fullScreen)[0]
        press(.fullScreen)
        let before = waitForPNGs(count: 2, after: .fullScreen)
        XCTAssertTrue(waitUntil(cards, count: 2), "expected 2 cards, found \(cards.count)")
        let cardFrames = cards.allElementsBoundByIndex.map(\.frame)
        press(.fullScreen)
        let withCards = try XCTUnwrap(waitForPNGs(count: 3, after: .fullScreen).first { !before.contains($0) })

        let region = cardFrames.reduce(CGRect.null) { $0.union($1) }
        let changed = try changedFraction(withoutCards, withCards, in: region)
        XCTAssertLessThan(changed, 0.01, "\(Int(changed * 100))% of the thumbnail area differs: the cards are in the capture")

        press(.window)
        waitForOverlay(after: .window)
        let onCard = point(onOverlayAt: CGVector(dx: region.midX - overlay.frame.minX, dy: region.midY - overlay.frame.minY))
        onCard.hover()
        onCard.click()
        assertNoNewPNG()
        overlay.typeKey(.escape, modifierFlags: [])
        assertOverlayClosed(after: .window)
    }

    @MainActor private var cards: XCUIElementQuery {
        app.images.matching(NSPredicate(format: "label BEGINSWITH %@", "Screenshot Glint "))
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

    /// The save panel's Save button; its window is the panel.
    @MainActor private func savePanelSaveButton() -> XCUIElement {
        let save = app.buttons.matching(NSPredicate(format: "label == 'Save' OR title == 'Save'")).firstMatch
        if !save.waitForExistence(timeout: Self.captureTimeout) {
            XCTFail("Save As showed no save panel. Glint's accessibility tree:\n\(app.debugDescription)")
        }
        return save
    }

    @MainActor private func cardSpread() -> CGFloat {
        let tops = cards.allElementsBoundByIndex.map(\.frame.minY)
        guard let low = tops.min(), let high = tops.max() else { return 0 }
        return high - low
    }

    @MainActor private func waitUntil(timeout: TimeInterval = GlintUITestCase.captureTimeout, _ condition: @escaping () -> Bool) -> Bool {
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
        let pixels = CGRect(x: (region.minX - screen.frame.minX) * scale, y: region.minY * scale,
                            width: region.width * scale, height: region.height * scale)
            .integral.intersection(CGRect(x: 0, y: 0, width: first.width, height: first.height))
        var changed = 0, total = 0
        for y in Int(pixels.minY)..<Int(pixels.maxY) {
            for x in Int(pixels.minX)..<Int(pixels.maxX) {
                let i = y * first.width * 4 + x * 4
                let differs = (0..<3).contains { abs(Int(first.bytes[i + $0]) - Int(second.bytes[i + $0])) > 8 }
                changed += differs ? 1 : 0
                total += 1
            }
        }
        return total == 0 ? 1 : Double(changed) / Double(total)
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
