import CoreGraphics
import Foundation

@MainActor
public final class AnnotationDocument {
    public let base: CGImage
    public private(set) var annotations: [Annotation] = []
    public let undoManager = UndoManager()
    public var onChange: (() -> Void)?

    public init(base: CGImage) {
        self.base = base
        // Grouping by run loop turn merges every change made in one turn into one undo step (undoStepsOneChangeAtATime).
        undoManager.groupsByEvent = false
    }

    public func annotation(_ id: UUID) -> Annotation? {
        annotations.first { $0.id == id }
    }

    public func topmostAnnotation(at point: CGPoint, tolerance: CGFloat) -> Annotation? {
        annotations.last { $0.contains(point, tolerance: tolerance) }
    }

    public func add(_ annotation: Annotation) {
        commit(annotations + [annotation], actionName: "Add \(annotation.kind.name)")
    }

    public func move(_ id: UUID, by delta: CGSize) {
        update(id, actionName: "Move") { $0.moved(by: delta) }
    }

    public func resize(_ id: UUID, _ handle: Annotation.Handle, to point: CGPoint) {
        update(id, actionName: "Resize") { $0.resized(handle, to: point) }
    }

    public func setText(_ id: UUID, _ text: String) {
        update(id, actionName: "Edit Text") { annotation in
            guard case .text(let previous) = annotation.kind else { return annotation }
            let lineHeight = annotation.bounds.height / CGFloat(AnnotationRenderer.lineCount(previous))
            return .text(text, at: annotation.bounds.origin, lineHeight: lineHeight, id: annotation.id)
        }
    }

    public func delete(_ id: UUID) {
        commit(annotations.filter { $0.id != id }, actionName: "Delete")
    }

    public func flattened() -> CGImage? {
        AnnotationRenderer.flatten(base, annotations)
    }

    private func update(_ id: UUID, actionName: String, _ change: (Annotation) -> Annotation) {
        commit(annotations.map { $0.id == id ? change($0) : $0 }, actionName: actionName)
    }

    private func commit(_ new: [Annotation], actionName: String) {
        let old = annotations
        guard new != old else { return }
        let isUndoOrRedo = undoManager.isUndoing || undoManager.isRedoing
        if !isUndoOrRedo { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self) { document in
            MainActor.assumeIsolated { document.commit(old, actionName: actionName) }
        }
        undoManager.setActionName(actionName)
        if !isUndoOrRedo { undoManager.endUndoGrouping() }
        annotations = new
        onChange?()
    }
}

extension Annotation.Kind {
    var name: String {
        switch self {
        case .arrow: "Arrow"
        case .rectangle: "Rectangle"
        case .text: "Text"
        case .highlighter: "Highlight"
        }
    }
}
