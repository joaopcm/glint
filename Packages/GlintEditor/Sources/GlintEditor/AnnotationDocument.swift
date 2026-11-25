import CoreGraphics
import Foundation

@MainActor
public final class AnnotationDocument {
    public let base: CGImage
    public private(set) var annotations: [Annotation] = []
    public private(set) var crop: CGRect?
    public let undoManager = UndoManager()
    public var onChange: (() -> Void)?
    let renderCache: AnnotationRenderCache

    public init(base: CGImage) {
        self.base = base
        renderCache = AnnotationRenderCache(base: base)
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
        commit(annotations + [annotation], crop: crop, actionName: "Add \(annotation.kind.name)")
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
        commit(annotations.filter { $0.id != id }, crop: crop, actionName: "Delete")
    }

    public func setCrop(_ rect: CGRect?) {
        let bounds = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        let clipped = rect.map { $0.standardized.integral.intersection(bounds) }
        let crop = clipped.flatMap { $0.isEmpty || $0 == bounds ? nil : $0 }
        commit(annotations, crop: crop, actionName: crop == nil ? "Remove Crop" : "Crop")
    }

    public func flattened() -> CGImage? {
        AnnotationRenderer.flatten(base, annotations, crop: crop, cache: renderCache)
    }

    private func update(_ id: UUID, actionName: String, _ change: (Annotation) -> Annotation) {
        commit(annotations.map { $0.id == id ? change($0) : $0 }, crop: crop, actionName: actionName)
    }

    private func commit(_ newAnnotations: [Annotation], crop newCrop: CGRect?, actionName: String) {
        let (oldAnnotations, oldCrop) = (annotations, crop)
        guard newAnnotations != oldAnnotations || newCrop != oldCrop else { return }
        let isUndoOrRedo = undoManager.isUndoing || undoManager.isRedoing
        if !isUndoOrRedo { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self) { document in
            MainActor.assumeIsolated { document.commit(oldAnnotations, crop: oldCrop, actionName: actionName) }
        }
        undoManager.setActionName(actionName)
        if !isUndoOrRedo { undoManager.endUndoGrouping() }
        annotations = newAnnotations
        crop = newCrop
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
        case .blur: "Blur"
        case .pixelate: "Pixelate"
        }
    }
}
