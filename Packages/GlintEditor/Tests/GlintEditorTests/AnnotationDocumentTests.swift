import CoreGraphics
import Foundation
import Testing
@testable import GlintEditor

@MainActor
struct AnnotationDocumentTests {
    let document = AnnotationDocument(base: solidImage(width: 200, height: 100))
    let box = Annotation(kind: .rectangle, start: CGPoint(x: 20, y: 20), end: CGPoint(x: 80, y: 60), lineWidth: 4)

    @Test func addsAnnotationsInDrawingOrder() {
        let arrow = Annotation(kind: .arrow, start: .zero, end: CGPoint(x: 10, y: 10), lineWidth: 4)
        document.add(box)
        document.add(arrow)
        #expect(document.annotations == [box, arrow])
    }

    @Test func movesBothPoints() {
        document.add(box)
        document.move(box.id, by: CGSize(width: 5, height: -10))
        #expect(document.annotation(box.id)?.start == CGPoint(x: 25, y: 10))
        #expect(document.annotation(box.id)?.end == CGPoint(x: 85, y: 50))
    }

    @Test func resizesOnlyTheDraggedHandle() {
        document.add(box)
        document.resize(box.id, .end, to: CGPoint(x: 150, y: 90))
        #expect(document.annotation(box.id)?.start == box.start)
        #expect(document.annotation(box.id)?.bounds == CGRect(x: 20, y: 20, width: 130, height: 70))
    }

    @Test func resizingPastTheOtherCornerKeepsAPositiveBox() {
        document.add(box)
        document.resize(box.id, .end, to: CGPoint(x: 0, y: 0))
        #expect(document.annotation(box.id)?.bounds == CGRect(x: 0, y: 0, width: 20, height: 20))
    }

    @Test func deletesOnlyThatAnnotation() {
        let other = Annotation(kind: .highlighter, start: .zero, end: CGPoint(x: 5, y: 5), lineWidth: 4)
        document.add(box)
        document.add(other)
        document.delete(box.id)
        #expect(document.annotations == [other])
    }

    @Test func editingTextKeepsTheLineHeightAndRefitsTheWidth() throws {
        let label = Annotation.text("hi", at: CGPoint(x: 10, y: 10), lineHeight: 20)
        document.add(label)
        document.setText(label.id, "a much longer label")
        let edited = try #require(document.annotation(label.id))
        #expect(edited.kind == .text("a much longer label"))
        #expect(edited.bounds.origin == label.bounds.origin)
        #expect(edited.bounds.height == 20)
        #expect(edited.bounds.width > label.bounds.width)
    }

    @Test func undoStepsOneChangeAtATime() {
        document.add(box)
        document.move(box.id, by: CGSize(width: 10, height: 0))
        document.delete(box.id)

        document.undoManager.undo()
        #expect(document.annotations == [box.moved(by: CGSize(width: 10, height: 0))])
        document.undoManager.undo()
        #expect(document.annotations == [box])
        document.undoManager.undo()
        #expect(document.annotations.isEmpty)
        #expect(!document.undoManager.canUndo)
    }

    @Test func redoReappliesUndoneChanges() {
        document.add(box)
        document.resize(box.id, .start, to: .zero)
        document.undoManager.undo()
        document.undoManager.undo()

        document.undoManager.redo()
        #expect(document.annotations == [box])
        document.undoManager.redo()
        #expect(document.annotation(box.id)?.start == .zero)
        #expect(!document.undoManager.canRedo)
    }

    @Test func undoNamesTheChange() {
        document.add(box)
        #expect(document.undoManager.undoActionName == "Add Rectangle")
        document.move(box.id, by: CGSize(width: 1, height: 1))
        #expect(document.undoManager.undoActionName == "Move")
    }

    @Test func noOpChangesAddNoUndoStep() {
        document.add(box)
        document.move(box.id, by: .zero)
        document.undoManager.undo()
        #expect(document.annotations.isEmpty)
    }

    @Test func changesNotifyTheCanvas() {
        var changes = 0
        document.onChange = { changes += 1 }
        document.add(box)
        document.undoManager.undo()
        #expect(changes == 2)
    }

    @Test func hitTestingPicksTheTopmost() {
        let top = Annotation(kind: .highlighter, start: CGPoint(x: 40, y: 30), end: CGPoint(x: 100, y: 90), lineWidth: 4)
        document.add(box)
        document.add(top)
        #expect(document.topmostAnnotation(at: CGPoint(x: 50, y: 40), tolerance: 0)?.id == top.id)
        #expect(document.topmostAnnotation(at: CGPoint(x: 25, y: 25), tolerance: 0)?.id == box.id)
        #expect(document.topmostAnnotation(at: CGPoint(x: 190, y: 5), tolerance: 0) == nil)
    }

    @Test func arrowsHitOnlyNearTheLine() {
        let arrow = Annotation(kind: .arrow, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 100), lineWidth: 4)
        #expect(arrow.contains(CGPoint(x: 50, y: 52), tolerance: 2))
        #expect(!arrow.contains(CGPoint(x: 90, y: 10), tolerance: 2))
    }
}
