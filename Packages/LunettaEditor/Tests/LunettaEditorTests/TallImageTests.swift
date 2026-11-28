import AppKit
import Testing
@testable import LunettaEditor

/// A 14" MacBook Pro's visible frame at its default scale, below the menu bar and above the Dock.
private let laptopScreen = CGRect(x: 0, y: 0, width: 1512, height: 945)

@MainActor
struct TallImageTests {
    private func openEditor(width: Int, height: Int) -> AnnotationEditor {
        let editor = AnnotationEditor(
            document: AnnotationDocument(base: solidImage(width: width, height: height)),
            title: "Test",
            pixelsPerPoint: 2,
            save: { _ in },
            onClose: {}
        )
        editor.fit(visibleFrame: laptopScreen)
        editor.window.layoutIfNeeded()
        return editor
    }

    @Test func tallImageOpensFitToWidth() {
        let editor = openEditor(width: 1600, height: 20000)
        let canvas = editor.canvas
        #expect(editor.window.frame.height == laptopScreen.height)
        #expect(canvas.imageRect.width == canvas.availableRect.width)
        #expect(canvas.imageRect.minY == canvas.availableRect.minY)
    }

    @Test func tallImagePansAtBaseMagnification() throws {
        let canvas = openEditor(width: 1600, height: 20000).canvas
        let before = canvas.imageRect
        canvas.scrollWheel(with: try #require(scrollEvent(points: -200)))
        #expect(canvas.magnification == 1)
        #expect(canvas.imageRect.minY == before.minY - 200)
    }

    @Test func zoomFitReturnsToFitWidth() {
        let editor = openEditor(width: 1600, height: 20000)
        let canvas = editor.canvas
        canvas.setMagnification(3)
        #expect(canvas.imageRect.width > canvas.availableRect.width)
        editor.zoomToFit()
        #expect(canvas.imageRect.width == canvas.availableRect.width)
    }

    @Test func normalImageFitIsUnchanged() throws {
        let editor = AnnotationEditor(
            document: AnnotationDocument(base: solidImage(width: 1600, height: 1000)),
            title: "Test",
            pixelsPerPoint: 2,
            save: { _ in },
            onClose: {}
        )
        let natural = editor.window.frame.size
        editor.fit(visibleFrame: laptopScreen)
        editor.window.layoutIfNeeded()
        let canvas = editor.canvas
        #expect(editor.window.frame.size == natural)
        // AppKit rounds the window's origin to whole points.
        #expect(abs(editor.window.frame.midX - laptopScreen.midX) <= 0.5)
        #expect(abs(editor.window.frame.midY - laptopScreen.midY) <= 0.5)
        #expect(canvas.imageRect.size == CGSize(width: 800, height: 500))
        let before = canvas.imageRect
        canvas.scrollWheel(with: try #require(scrollEvent(points: -200)))
        #expect(canvas.imageRect == before)
    }

    @Test func annotationOnScrolledTallImageLandsWhereDrawn() throws {
        let editor = openEditor(width: 1600, height: 20000)
        let canvas = editor.canvas
        canvas.pan(by: CGSize(width: 0, height: -2000))
        canvas.tool = .rectangle
        let available = canvas.availableRect
        let start = CGPoint(x: available.midX - 100, y: available.midY - 50)
        let end = CGPoint(x: available.midX + 100, y: available.midY + 50)
        canvas.mouseDown(with: mouseEvent(.leftMouseDown, at: start, in: canvas))
        canvas.mouseDragged(with: mouseEvent(.leftMouseDragged, at: end, in: canvas))
        canvas.mouseUp(with: mouseEvent(.leftMouseUp, at: end, in: canvas))

        let rect = canvas.imageRect
        let pixelsPerViewPoint = 1600 / rect.width
        let underPointer = CGPoint(x: (start.x - rect.minX) * pixelsPerViewPoint, y: (start.y - rect.minY) * pixelsPerViewPoint)
        #expect(underPointer.y > 4000)

        let flattened = try #require(canvas.document.flattened())
        #expect(flattened.height == 20000)
        let leftEdge = try #require(flattened.cropping(to: CGRect(x: underPointer.x - 4, y: underPointer.y + 20, width: 8, height: 40)))
        #expect(Pixels(leftEdge).inkCount(in: CGRect(x: 0, y: 0, width: 8, height: 40)) > 0)
        let top = try #require(flattened.cropping(to: CGRect(x: 0, y: 0, width: 1600, height: 1000)))
        #expect(Pixels(top).inkCount(in: CGRect(x: 0, y: 0, width: 1600, height: 1000)) == 0)
    }

    private func scrollEvent(points: Int32) -> NSEvent? {
        CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: points, wheel2: 0, wheel3: 0)
            .flatMap { NSEvent(cgEvent: $0) }
    }

    private func mouseEvent(_ type: NSEvent.EventType, at viewPoint: CGPoint, in canvas: EditorCanvas) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: canvas.convert(viewPoint, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: canvas.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
    }
}
