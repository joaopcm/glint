import CoreGraphics
import Testing
@testable import LunettaEditor

@MainActor
struct TextHighlightTests {
    let lines = [r(10, 10, 50, 20), r(10, 40, 30, 20)]

    @Test func movingOffsetsLinesAndUndoRestores() {
        let document = AnnotationDocument(base: solidImage(width: 200, height: 100))
        let highlight = Annotation.textHighlight(lines)
        document.add(highlight)
        document.move(highlight.id, by: CGSize(width: 5, height: 5))
        #expect(document.annotation(highlight.id)?.lines == [r(15, 15, 50, 20), r(15, 45, 30, 20)])
        document.undoManager.undo()
        #expect(document.annotation(highlight.id)?.lines == lines)
    }

    @Test func textHighlightSpansItsLines() {
        #expect(Annotation.textHighlight(lines).bounds == r(10, 10, 50, 50))
    }

    @Test func textHighlightHasNoHandles() {
        #expect(Annotation.textHighlight(lines).handles.isEmpty)
    }

    @Test func textHighlightHitsOnlyItsLines() {
        let highlight = Annotation.textHighlight(lines)
        #expect(!highlight.contains(CGPoint(x: 55, y: 50), tolerance: 0))
        #expect(highlight.contains(CGPoint(x: 20, y: 50), tolerance: 0))
    }

    @Test func textHighlightFillsOnlyLines() throws {
        let image = try #require(AnnotationRenderer.flatten(solidImage(width: 200, height: 100), [.textHighlight(lines)]))
        let pixels = Pixels(image)
        #expect(!pixels.isWhite(x: 20, y: 20))
        #expect(pixels.isWhite(x: 55, y: 50))
    }

    @Test func overlappingLinesTintEvenly() throws {
        let overlapping = [r(10, 10, 50, 20), r(10, 25, 50, 20)]
        let pixels = Pixels(try #require(AnnotationRenderer.flatten(solidImage(width: 200, height: 100), [.textHighlight(overlapping)])))
        #expect(pixels.rgb(x: 20, y: 27) == pixels.rgb(x: 20, y: 15))
    }
}
