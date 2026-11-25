import AppKit
import XCTest

/// Runs once per corner through the subclass below: the card has to leave through its own side of the screen (#92).
class CardExitUITests: LunettaUITestCase {
    var expectedEdge: String { "right" }

    @MainActor func testCloseSlidesTheCardOutThroughItsOwnEdge() throws {
        press(.fullScreen)
        let png = waitForPNGs(count: 1, after: .fullScreen)[0]
        let card = app.images["Screenshot \(png.lastPathComponent)"]
        XCTAssertTrue(card.waitForExistence(timeout: Self.captureTimeout), "no thumbnail for \(png.lastPathComponent)")
        let start = settledFrame(of: card)
        center(of: card).hover()
        let close = app.buttons["Close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: Self.captureTimeout), "hovering shows no Close button")
        let closePoint = center(of: close)

        // XCUITest's click returns after the 200 ms exit is over (run 45611987356), so the window server is sampled from another thread.
        let pid = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: Self.lunettaBundleID).first?.processIdentifier)
        let sampler = WindowSampler(pid: pid, size: start.size)
        sampler.start()
        closePoint.click()
        XCTAssertTrue(waitUntilGone(card), "Close left the card on screen")
        let xs = sampler.stop()
        XCTContext.runActivity(named: "card x while leaving \(expectedEdge): \(start.minX) then \(xs.map { Int($0) })") { _ in }

        let moved = expectedEdge == "right" ? xs.contains { $0 > start.minX + 1 } : xs.contains { $0 < start.minX - 1 }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            XCTAssertTrue(xs.allSatisfy { abs($0 - start.minX) < 1 }, "Reduce Motion is on, yet the card moved from x \(start.minX) to \(xs) instead of fading in place")
        } else {
            XCTAssertTrue(moved, "the card started at x \(start.minX) and was seen at \(xs) while leaving, never toward the \(expectedEdge) edge")
        }
    }

    @MainActor private func waitUntilGone(_ element: XCUIElement) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter.wait(for: [gone], timeout: Self.captureTimeout) == .completed
    }
}

final class CardExitLeftCornerUITests: CardExitUITests {
    override var overlayCorner: String { "bottomLeft" }
    override var expectedEdge: String { "left" }
}

/// Collects the x of every on-screen window of `pid` with the card's size, as fast as the window server answers.
private final class WindowSampler {
    private let pid: pid_t
    private let size: CGSize
    private let lock = NSLock()
    private var xs: [CGFloat] = []
    private var running = true

    init(pid: pid_t, size: CGSize) {
        self.pid = pid
        self.size = size
    }

    func start() {
        Thread.detachNewThread { [self] in
            while lock.withLock({ running }) {
                let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
                let cards = windows.compactMap { info -> CGRect? in
                    guard info[kCGWindowOwnerPID as String] as? pid_t == pid,
                          let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                          let frame = CGRect(dictionaryRepresentation: bounds),
                          abs(frame.width - size.width) < 1, abs(frame.height - size.height) < 1
                    else { return nil }
                    return frame
                }
                lock.withLock { xs += cards.map(\.minX) }
            }
        }
    }

    func stop() -> [CGFloat] {
        lock.withLock {
            running = false
            return xs
        }
    }
}
