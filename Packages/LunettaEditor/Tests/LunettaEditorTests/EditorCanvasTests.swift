import CoreGraphics
import Testing
@testable import LunettaEditor

@MainActor
struct EditorCanvasTests {
    @Test func aCanvasReopenedOnTheSameDocumentShowsItsObjects() {
        let document = AnnotationDocument(base: solidImage(width: 200, height: 100))
        _ = EditorCanvas(document: document, pixelsPerPoint: 2)
        document.add(Annotation(kind: .rectangle, start: CGPoint(x: 20, y: 20), end: CGPoint(x: 80, y: 60), lineWidth: 4))

        let reopened = EditorCanvas(document: document, pixelsPerPoint: 2)
        reopened.documentChanged()
        #expect(reopened.accessibilityValue() as? String == "1 annotation, nothing selected")
    }

    @Test func accessibilityValueCountsAnnotations() {
        let document = AnnotationDocument(base: solidImage(width: 200, height: 100))
        let canvas = EditorCanvas(document: document, pixelsPerPoint: 1)
        canvas.documentChanged()
        #expect(canvas.accessibilityValue() as? String == "0 annotations, nothing selected")
    }
}
