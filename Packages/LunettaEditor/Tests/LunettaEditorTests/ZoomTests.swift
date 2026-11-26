import AppKit
import Testing
@testable import LunettaEditor

@MainActor
struct ZoomTests {
    /// 400×300 px at 1 px per point fits an 800×600 pt canvas at its real size.
    private func makeCanvas(width: Int = 400, height: Int = 300, pixelsPerPoint: CGFloat = 1) -> EditorCanvas {
        let canvas = EditorCanvas(document: AnnotationDocument(base: solidImage(width: width, height: height)), pixelsPerPoint: pixelsPerPoint)
        canvas.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        return canvas
    }

    @Test func zoomingKeepsThePointUnderTheAnchorStill() {
        let canvas = makeCanvas()
        #expect(canvas.imageRect == CGRect(x: 200, y: 150, width: 400, height: 300))
        canvas.setMagnification(4, anchoredAt: CGPoint(x: 300, y: 200))
        // Image point (100, 50) was under the anchor and still is: 300 = -100 + 100×4, 200 = 0 + 50×4.
        #expect(canvas.imageRect == CGRect(x: -100, y: 0, width: 1600, height: 1200))
    }

    /// 3200×2400 px at 2 px per point fits 800×600 pt at 50%, so the zoom runs from 50% to 800%.
    @Test func zoomStaysBetweenFittingTheWindowAndEightTimesTheRealSize() {
        let canvas = makeCanvas(width: 3200, height: 2400, pixelsPerPoint: 2)
        #expect(canvas.zoomPercent == 50)
        canvas.setMagnification(100)
        #expect(canvas.zoomPercent == 800)
        canvas.setMagnification(0.1)
        #expect(canvas.magnification == 1)
        #expect(canvas.zoomPercent == 50)
    }

    @Test func theSliderPositionZoomsLogarithmically() {
        let canvas = makeCanvas(width: 3200, height: 2400, pixelsPerPoint: 2)
        canvas.zoomPosition = 0.5
        #expect(canvas.zoomPercent == 200)
        #expect(abs(canvas.zoomPosition - 0.5) < 0.0001)
        canvas.zoomPosition = 1
        #expect(canvas.zoomPercent == 800)
    }

    @Test func panningStopsWhereTheImageEdgeMeetsTheCanvas() {
        let canvas = makeCanvas()
        canvas.setMagnification(4)
        canvas.pan(by: CGSize(width: -10_000, height: -10_000))
        #expect(canvas.imageRect.maxX == 800)
        #expect(canvas.imageRect.maxY == 600)
        canvas.pan(by: CGSize(width: 10_000, height: 10_000))
        #expect(canvas.imageRect.minX == 0)
        #expect(canvas.imageRect.minY == 0)
    }

    @Test func zoomingBackOutCentersTheImageAgain() {
        let canvas = makeCanvas()
        canvas.setMagnification(4, anchoredAt: CGPoint(x: 10, y: 10))
        canvas.setMagnification(1)
        #expect(canvas.imageRect == CGRect(x: 200, y: 150, width: 400, height: 300))
    }

    @Test func commandScrollZoomsAndPlainScrollAtFitDoesNot() throws {
        let canvas = makeCanvas()
        canvas.scrollWheel(with: try #require(scrollEvent(lines: 3, flags: [])))
        #expect(canvas.magnification == 1)
        canvas.scrollWheel(with: try #require(scrollEvent(lines: 3, flags: .maskCommand)))
        #expect(canvas.magnification > 1)
    }

    @Test func theZoomControlTracksTheCanvas() throws {
        let editor = AnnotationEditor(
            document: AnnotationDocument(base: solidImage(width: 3024, height: 1964)),
            title: "Test",
            pixelsPerPoint: 2,
            save: { _ in },
            onClose: {}
        )
        try #require(editor.window.contentView).layoutSubtreeIfNeeded()
        #expect(!editor.zoomButton.isEnabled)

        editor.zoomSlider.doubleValue = 1
        editor.zoomSliderChanged()
        #expect(editor.canvas.zoomPercent == 800)
        #expect(editor.zoomButton.title == "800%")
        #expect(editor.zoomButton.isEnabled)

        editor.zoomToFit()
        #expect(editor.canvas.magnification == 1)
        #expect(editor.zoomSlider.doubleValue == 0)
    }

    /// 3024×1964 is a 14" MacBook Pro screen at 2 px per point: the image fills the canvas right down to its inset.
    @Test(arguments: [(200, 100), (3024, 1964)])
    func theZoomControlNeverCoversTheFittedImage(width: Int, height: Int) throws {
        let editor = AnnotationEditor(
            document: AnnotationDocument(base: solidImage(width: width, height: height)),
            title: "Test",
            pixelsPerPoint: 2,
            save: { _ in },
            onClose: {}
        )
        let content = try #require(editor.window.contentView)
        content.layoutSubtreeIfNeeded()
        let zoom = editor.zoomControl.convert(editor.zoomControl.bounds, to: nil)
        let image = editor.canvas.convert(editor.canvas.imageRect, to: nil)
        #expect(!zoom.intersects(image), "zoom control \(zoom) covers image \(image)")
        #expect(zoom.maxX <= content.bounds.width - 16, "zoom control \(zoom) spills out of a \(content.bounds.width) pt window")
    }

    private func scrollEvent(lines: Int32, flags: CGEventFlags) -> NSEvent? {
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0)
        event?.flags = flags
        return event.flatMap { NSEvent(cgEvent: $0) }
    }
}
