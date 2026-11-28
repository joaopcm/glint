import AppKit
import LunettaCapture
import LunettaCore
import Testing
@testable import Lunetta

@MainActor struct ScrollingStageTests {
    let display = DisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900), scale: 2)
    let area = CGRect(x: 200, y: 300, width: 600, height: 400)

    @Test func previewPixelHeightIsTheStripInPixelsOfTheAreasDisplay() {
        let stage = ScrollingStage()
        stage.prepare(area, on: display)
        defer { stage.dismiss() }

        #expect(stage.previewPixelHeight == Int(ScrollingStage.previewHeight * 2))
    }

    @Test func stagedWindowsAreChromeUntilTheStageCloses() {
        let stage = ScrollingStage()
        stage.prepare(area, on: display)
        let ids = stage.windows.map { UInt32($0.windowNumber) }

        #expect(stage.windows.count == 2)
        #expect(Set(ids).isSubset(of: Set(CaptureChrome.windowIDs())))

        stage.finish()

        #expect(stage.windows.isEmpty)
    }

    @Test func outlineLetsThePointerThroughAndControlsNeverTakeTheKeyboard() throws {
        let stage = ScrollingStage()
        stage.prepare(area, on: display)
        defer { stage.dismiss() }
        let outline = try #require(stage.windows.first)
        let controls = try #require(stage.windows.last)

        #expect(outline.ignoresMouseEvents)
        #expect(outline.frame == display.frame)
        #expect(!controls.canBecomeKey)
        #expect(controls.styleMask.contains(.nonactivatingPanel))
        #expect(controls.isVisible && outline.isVisible)
    }

    @Test func doneResolvesTheDecisionAndOrdersTheWindowsOutAtOnce() async {
        let stage = ScrollingStage()
        stage.prepare(area, on: display)
        let windows = stage.windows

        stage.finish()

        #expect(windows.allSatisfy { !$0.isVisible })
        #expect(await stage.decision() == .done)
    }

    @Test func cancelResolvesCancelled() async {
        let stage = ScrollingStage()
        stage.prepare(area, on: display)
        stage.cancel()

        #expect(await stage.decision() == .cancelled)
    }

    @Test func dismissResolvesAPendingDecisionWithCancelled() async {
        let stage = ScrollingStage()
        stage.prepare(area, on: display)
        let waiting = Task { await stage.decision() }
        await Task.yield()

        stage.dismiss()

        #expect(await waiting.value == .cancelled)
    }

    @Test func aClosedStageStaysClosed() async {
        let stage = ScrollingStage()
        stage.prepare(area, on: display)
        stage.dismiss()
        stage.finish()

        #expect(await stage.decision() == .cancelled)
        #expect(stage.windows.isEmpty)
    }

    @Test func showUpdatesHeightAndStatusUntilTheDecision() {
        let stage = ScrollingStage()
        stage.prepare(area, on: display)

        stage.show(StitchUpdate(state: .lostOverlap, height: 1600, appendedRows: 0), preview: nil)
        #expect(stage.heightText == "800 pt")
        #expect(stage.statusText == "Scroll back — lost the overlap")

        stage.finish()
        stage.show(StitchUpdate(state: .tracking, height: 4000, appendedRows: 10), preview: nil)
        #expect(stage.heightText == "800 pt")
        #expect(stage.statusText == "Scroll back — lost the overlap")
    }

    @Test func statusNamesTheProblemOrNothing() {
        #expect(ScrollingStage.status(for: .tracking) == nil)
        #expect(ScrollingStage.status(for: .lostOverlap) == "Scroll back — lost the overlap")
        #expect(ScrollingStage.status(for: .heightLimitReached(limit: 40_000)) == "Height limit 40000 px reached")
    }

    @Test func heightIsShownInPointsOfTheDisplay() {
        #expect(ScrollingStage.heightLabel(pixels: 3000, scale: 2) == "1500 pt")
        #expect(ScrollingStage.heightLabel(pixels: 333, scale: 1) == "333 pt")
    }

    @Test func aNewCaptureStartsAFreshStage() async {
        let stage = ScrollingStage()
        stage.prepare(area, on: display)
        stage.cancel()
        stage.prepare(area, on: display)
        stage.finish()

        #expect(await stage.decision() == .done)
    }
}
