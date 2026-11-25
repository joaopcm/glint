import AppKit
import XCTest

/// Runs once per corner through the subclass below: the card has to leave through its own side of the screen (#92).
class CardExitUITests: GlintUITestCase {
    var expectedEdge: String { "right" }

    @MainActor func testCloseSlidesTheCardOutThroughItsOwnEdge() {
        press(.fullScreen)
        let png = waitForPNGs(count: 1, after: .fullScreen)[0]
        let card = app.images["Screenshot \(png.lastPathComponent)"]
        XCTAssertTrue(card.waitForExistence(timeout: Self.captureTimeout), "no thumbnail for \(png.lastPathComponent)")
        let start = settledFrame(of: card)
        let towardScreenEdge = expectedEdge == "right" ? start.midX > pointerScreen.frame.midX : start.midX < pointerScreen.frame.midX
        XCTAssertTrue(towardScreenEdge, "the card at \(start) isn't on the \(expectedEdge) half of the screen")

        center(of: card).hover()
        let close = app.buttons["Close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: Self.captureTimeout), "hovering shows no Close button")
        center(of: close).click()
        var xs: [CGFloat] = [card.frame.minX]
        keepScreenshot(named: "card leaving through the \(expectedEdge) edge")
        let deadline = Date().addingTimeInterval(Self.captureTimeout)
        while card.exists, Date() < deadline {
            xs.append(card.frame.minX)
        }
        XCTAssertFalse(card.exists, "Close left the card on screen")
        let moved = expectedEdge == "right" ? xs.contains { $0 > start.minX + 1 } : xs.contains { $0 < start.minX - 1 }
        XCTAssertTrue(moved, "the card started at x \(start.minX) and was seen at \(xs) while leaving, never toward the \(expectedEdge) edge")
    }
}

final class CardExitLeftCornerUITests: CardExitUITests {
    override var overlayCorner: String { "bottomLeft" }
    override var expectedEdge: String { "left" }
}
