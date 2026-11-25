import AppKit
import Carbon.HIToolbox

@MainActor
public final class EditorCanvas: NSView, NSTextFieldDelegate {
    public enum Tool: CaseIterable {
        case select, arrow, rectangle, text, highlighter, blur, pixelate, crop

        var kind: Annotation.Kind? {
            switch self {
            case .select, .text, .crop: nil
            case .arrow: .arrow
            case .rectangle: .rectangle
            case .highlighter: .highlighter
            case .blur: .blur
            case .pixelate: .pixelate
            }
        }
    }

    private enum Gesture {
        case drawing(Annotation)
        case moving(UUID, from: CGPoint, to: CGPoint)
        case resizing(UUID, Annotation.Handle, to: CGPoint)
        case cropping(from: CGPoint, to: CGPoint)
    }

    public var tool: Tool = .arrow {
        didSet {
            onToolChange?(tool)
            window?.invalidateCursorRects(for: self)
        }
    }
    public var onToolChange: ((Tool) -> Void)?
    public var onSave: (() -> Void)?
    public private(set) var selectedID: UUID? {
        didSet {
            guard selectedID != oldValue else { return }
            needsDisplay = true
            updateAccessibilityValue()
        }
    }

    let document: AnnotationDocument
    private let lineWidth: CGFloat
    private let textLineHeight: CGFloat
    private var gesture: Gesture?
    private var textField: NSTextField?
    private var editingTextID: UUID?
    private var textFieldOrigin: CGPoint = .zero
    private var textFieldLineHeight: CGFloat = 0

    private static let handleSize: CGFloat = 8
    private static let hitTolerance: CGFloat = 6
    // Same as ThumbnailView.dragThreshold: a click with a slight jitter draws nothing.
    private static let minimumDrag: CGFloat = 4

    public init(document: AnnotationDocument, pixelsPerPoint: CGFloat) {
        self.document = document
        lineWidth = 3 * pixelsPerPoint
        textLineHeight = 28 * pixelsPerPoint
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Annotation canvas")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public func documentChanged() {
        if let selectedID, document.annotation(selectedID) == nil { self.selectedID = nil }
        updateAccessibilityValue()
        needsDisplay = true
    }

    private func updateAccessibilityValue() {
        let count = document.annotations.count
        let selected = selectedID.flatMap(document.annotation).map { "\($0.kind.name) selected" } ?? "nothing selected"
        setAccessibilityValue("\(count) annotation\(count == 1 ? "" : "s"), \(selected)")
    }

    private var imageSize: CGSize {
        CGSize(width: document.base.width, height: document.base.height)
    }

    private var zoom: CGFloat {
        min(bounds.width / imageSize.width, bounds.height / imageSize.height)
    }

    private var imageRect: CGRect {
        let size = CGSize(width: imageSize.width * zoom, height: imageSize.height * zoom)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }

    private func imagePoint(for event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        let rect = imageRect
        return CGPoint(
            x: min(max((p.x - rect.minX) / zoom, 0), imageSize.width),
            y: min(max((p.y - rect.minY) / zoom, 0), imageSize.height)
        )
    }

    private func viewPoint(_ imagePoint: CGPoint) -> CGPoint {
        CGPoint(x: imageRect.minX + imagePoint.x * zoom, y: imageRect.minY + imagePoint.y * zoom)
    }

    private var displayedAnnotations: [Annotation] {
        switch gesture {
        case nil:
            return document.annotations
        case .drawing(let draft):
            return document.annotations + [draft]
        case .moving(let id, let from, let to):
            return document.annotations.map { $0.id == id ? $0.moved(by: CGSize(width: to.x - from.x, height: to.y - from.y)) : $0 }
        case .resizing(let id, let handle, let to):
            return document.annotations.map { $0.id == id ? $0.resized(handle, to: to) : $0 }
        case .cropping:
            return document.annotations
        }
    }

    private var displayedCrop: CGRect? {
        guard case .cropping(let from, let to) = gesture else { return document.crop }
        return CGRect(x: min(from.x, to.x), y: min(from.y, to.y), width: abs(to.x - from.x), height: abs(to.y - from.y))
    }

    public override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill()
        bounds.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let annotations = displayedAnnotations

        context.saveGState()
        context.translateBy(x: imageRect.minX, y: imageRect.minY)
        context.scaleBy(x: zoom, y: zoom)
        context.interpolationQuality = .high
        context.saveGState()
        context.translateBy(x: 0, y: imageSize.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(document.base, in: CGRect(origin: .zero, size: imageSize))
        context.restoreGState()
        let visibleAnnotations = editingTextID == nil ? annotations : annotations.filter { $0.id != editingTextID }
        AnnotationRenderer.draw(visibleAnnotations, over: document.base, inFlippedContext: context, cache: document.renderCache)
        context.restoreGState()

        if let crop = displayedCrop {
            drawCrop(crop)
        }

        if let selected = annotations.first(where: { $0.id == selectedID }) {
            drawSelection(of: selected)
        }
    }

    private func drawSelection(of annotation: Annotation) {
        if annotation.kind != .arrow {
            let outline = NSBezierPath(rect: CGRect(origin: viewPoint(annotation.bounds.origin), size: CGSize(
                width: annotation.bounds.width * zoom, height: annotation.bounds.height * zoom
            )))
            outline.lineWidth = 1
            outline.setLineDash([4, 3], count: 2, phase: 0)
            NSColor.controlAccentColor.setStroke()
            outline.stroke()
        }
        for handle in Annotation.Handle.allCases {
            let center = viewPoint(annotation.point(of: handle))
            let square = NSBezierPath(rect: CGRect(x: center.x - Self.handleSize / 2, y: center.y - Self.handleSize / 2, width: Self.handleSize, height: Self.handleSize))
            NSColor.white.setFill()
            square.fill()
            NSColor.controlAccentColor.setStroke()
            square.lineWidth = 1.5
            square.stroke()
        }
    }

    private func drawCrop(_ crop: CGRect) {
        let kept = CGRect(origin: viewPoint(crop.origin), size: CGSize(width: crop.width * zoom, height: crop.height * zoom))
        let outside = NSBezierPath(rect: imageRect)
        outside.append(NSBezierPath(rect: kept))
        outside.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.55).setFill()
        outside.fill()
        let border = NSBezierPath(rect: kept)
        border.lineWidth = 1
        NSColor.white.setStroke()
        border.stroke()
    }

    public override func resetCursorRects() {
        addCursorRect(imageRect, cursor: tool == .select ? .arrow : tool == .text ? .iBeam : .crosshair)
    }

    public override func mouseDown(with event: NSEvent) {
        if textField != nil { endTextEditing(commit: true) }
        window?.makeFirstResponder(self)
        let point = imagePoint(for: event)
        let tolerance = Self.hitTolerance / zoom

        if event.clickCount == 2, let hit = document.topmostAnnotation(at: point, tolerance: tolerance), case .text = hit.kind {
            return beginTextEditing(hit)
        }
        if let selectedID, let selected = document.annotation(selectedID),
           let handle = Annotation.Handle.allCases.first(where: { isNear(selected.point(of: $0), point) }) {
            gesture = .resizing(selectedID, handle, to: point)
            return
        }
        switch tool {
        case .select:
            selectedID = document.topmostAnnotation(at: point, tolerance: tolerance)?.id
            gesture = selectedID.map { .moving($0, from: point, to: point) }
        case .text:
            beginTextEntry(at: point)
        case .crop:
            selectedID = nil
            gesture = .cropping(from: point, to: point)
        case .arrow, .rectangle, .highlighter, .blur, .pixelate:
            selectedID = nil
            gesture = tool.kind.map { .drawing(Annotation(kind: $0, start: point, end: point, lineWidth: lineWidth)) }
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        let point = imagePoint(for: event)
        switch gesture {
        case nil: return
        case .drawing(let draft): gesture = .drawing(draft.resized(.end, to: point))
        case .moving(let id, let from, _): gesture = .moving(id, from: from, to: point)
        case .resizing(let id, let handle, _): gesture = .resizing(id, handle, to: point)
        case .cropping(let from, _): gesture = .cropping(from: from, to: point)
        }
        needsDisplay = true
    }

    public override func mouseUp(with event: NSEvent) {
        defer {
            gesture = nil
            needsDisplay = true
        }
        switch gesture {
        case nil:
            return
        case .drawing(let draft):
            guard hypot(draft.end.x - draft.start.x, draft.end.y - draft.start.y) * zoom >= Self.minimumDrag else { return }
            document.add(draft)
            selectedID = draft.id
        case .moving(let id, let from, let to):
            document.move(id, by: CGSize(width: to.x - from.x, height: to.y - from.y))
        case .resizing(let id, let handle, let to):
            document.resize(id, handle, to: to)
        case .cropping(let from, let to):
            guard hypot(to.x - from.x, to.y - from.y) * zoom >= Self.minimumDrag, let crop = displayedCrop else { return }
            document.setCrop(crop)
        }
    }

    private func isNear(_ handle: CGPoint, _ point: CGPoint) -> Bool {
        hypot(handle.x - point.x, handle.y - point.y) * zoom <= Self.handleSize
    }

    public override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch Int(event.keyCode) {
        case kVK_Delete, kVK_ForwardDelete:
            if let selectedID {
                document.delete(selectedID)
            } else if tool == .crop {
                document.setCrop(nil)
            }
        case kVK_Escape:
            if gesture != nil {
                gesture = nil
                needsDisplay = true
            } else {
                selectedID = nil
            }
        default:
            guard modifiers.isEmpty, let tool = Self.shortcuts[event.charactersIgnoringModifiers ?? ""] else {
                return super.keyDown(with: event)
            }
            self.tool = tool
        }
    }

    static let shortcuts: [String: Tool] = [
        "v": .select, "a": .arrow, "r": .rectangle, "t": .text, "h": .highlighter, "b": .blur, "p": .pixelate, "c": .crop,
    ]

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch (event.charactersIgnoringModifiers?.lowercased(), modifiers) {
        case ("z", [.command]):
            document.undoManager.undo()
        case ("z", [.command, .shift]):
            document.undoManager.redo()
        case ("s", [.command]):
            onSave?()
        default:
            return super.performKeyEquivalent(with: event)
        }
        return true
    }

    private func beginTextEntry(at point: CGPoint) {
        selectedID = nil
        showTextField(at: point, text: "", lineHeight: textLineHeight)
    }

    private func beginTextEditing(_ annotation: Annotation) {
        guard case .text(let text) = annotation.kind else { return }
        selectedID = annotation.id
        editingTextID = annotation.id
        let lines = CGFloat(AnnotationRenderer.lineCount(text))
        showTextField(at: annotation.bounds.origin, text: text, lineHeight: annotation.bounds.height / lines)
    }

    private func showTextField(at imageOrigin: CGPoint, text: String, lineHeight: CGFloat) {
        let field = NSTextField(string: text)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = AnnotationRenderer.textFont(fittingLineHeight: lineHeight * zoom)
        field.textColor = NSColor(cgColor: AnnotationRenderer.ink)
        field.placeholderString = "Text"
        field.delegate = self
        field.setAccessibilityLabel("Annotation text")
        field.sizeToFit()
        field.frame = CGRect(origin: viewPoint(imageOrigin), size: CGSize(width: max(field.frame.width, 200), height: field.frame.height))
        addSubview(field)
        textField = field
        textFieldOrigin = imageOrigin
        textFieldLineHeight = lineHeight
        window?.makeFirstResponder(field)
        needsDisplay = true
    }

    private func endTextEditing(commit: Bool) {
        guard let field = textField else { return }
        textField = nil
        let editingID = editingTextID
        editingTextID = nil
        field.delegate = nil
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
        needsDisplay = true
        let text = field.stringValue
        guard commit else { return }
        switch (editingID, text.isEmpty) {
        case (let id?, true):
            document.delete(id)
        case (let id?, false):
            document.setText(id, text)
        case (nil, false):
            let label = Annotation.text(text, at: textFieldOrigin, lineHeight: textFieldLineHeight)
            document.add(label)
            selectedID = label.id
        case (nil, true):
            return
        }
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            endTextEditing(commit: true)
        case #selector(NSResponder.cancelOperation(_:)):
            endTextEditing(commit: false)
        default:
            return false
        }
        return true
    }

    public func controlTextDidEndEditing(_ notification: Notification) {
        endTextEditing(commit: true)
    }
}
