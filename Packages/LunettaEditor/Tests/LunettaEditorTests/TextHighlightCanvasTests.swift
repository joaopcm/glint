import AppKit
import Testing
@testable import LunettaEditor

@MainActor
struct TextHighlightCanvasTests {
    @Test func loadTextLayoutReadsFixture() async throws {
        let document = AnnotationDocument(base: try twoLinesFixture())
        await document.loadTextLayout()
        #expect(document.textLayout?.lines.count == 2)
    }

    @Test func dragAcrossWordsAddsOneTextHighlight() {
        let harness = HighlighterHarness(layout: threeLines)
        harness.drag(from: CGPoint(x: 60, y: 10), to: CGPoint(x: 10, y: 70))
        #expect(harness.document.annotations.map(\.lines.count) == [3])
    }

    @Test func clickOnWordHighlightsIt() {
        let harness = HighlighterHarness(layout: threeLines)
        harness.drag(from: CGPoint(x: 60, y: 10), to: CGPoint(x: 60, y: 10))
        #expect(harness.document.annotations.map(\.lines.count) == [1])
    }

    @Test func freeRectWhenNoTextUnderPointer() {
        let harness = HighlighterHarness(layout: threeLines)
        harness.drag(from: CGPoint(x: 160, y: 10), to: CGPoint(x: 195, y: 90))
        #expect(harness.document.annotations.map(\.lines) == [[]])
        #expect(harness.document.annotations.first?.bounds == CGRect(x: 160, y: 10, width: 35, height: 80))
    }

    @Test func freeRectWhileLayoutPending() {
        let harness = HighlighterHarness(layout: nil)
        harness.drag(from: CGPoint(x: 60, y: 10), to: CGPoint(x: 120, y: 10))
        #expect(harness.document.annotations.map(\.lines) == [[]])
    }
}

/// A highlighter canvas in a 400×300 window over a 200×100 image, unscaled.
@MainActor
private final class HighlighterHarness {
    let document = AnnotationDocument(base: solidImage(width: 200, height: 100))
    let canvas: EditorCanvas
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)

    init(layout: TextLayout?) {
        document.textLayout = layout
        canvas = EditorCanvas(document: document, pixelsPerPoint: 1)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        canvas.tool = .highlighter
    }

    func drag(from start: CGPoint, to end: CGPoint) {
        canvas.mouseDown(with: event(.leftMouseDown, at: start))
        canvas.mouseDragged(with: event(.leftMouseDragged, at: end))
        canvas.mouseUp(with: event(.leftMouseUp, at: end))
    }

    private func event(_ type: NSEvent.EventType, at imagePoint: CGPoint) -> NSEvent {
        let rect = canvas.imageRect
        let viewPoint = CGPoint(x: rect.minX + imagePoint.x, y: rect.minY + imagePoint.y)
        return NSEvent.mouseEvent(
            with: type, location: canvas.convert(viewPoint, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
    }
}
