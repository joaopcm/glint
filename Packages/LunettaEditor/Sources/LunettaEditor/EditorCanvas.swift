import AppKit
import Carbon.HIToolbox

@MainActor
public final class EditorCanvas: NSView, NSTextFieldDelegate {
    public enum Tool: CaseIterable, Sendable {
        case select, arrow, rectangle, text, highlighter, blur, pixelate, crop

        /// The tool that draws `kind`, if the dock slider adjusts it.
        init?(sliding kind: Annotation.Kind) {
            switch kind {
            case .arrow: self = .arrow
            case .blur: self = .blur
            case .pixelate: self = .pixelate
            case .rectangle, .text, .highlighter: return nil
            }
        }

        var sliderScale: SliderScale? {
            switch self {
            case .arrow: .arrowThickness
            case .blur, .pixelate: .obscuring
            case .select, .rectangle, .text, .highlighter, .crop: nil
            }
        }

        public var shortcut: String {
            switch self {
            case .select: "v"
            case .arrow: "a"
            case .rectangle: "r"
            case .text: "t"
            case .highlighter: "h"
            case .blur: "b"
            case .pixelate: "p"
            case .crop: "c"
            }
        }
    }

    private enum Gesture {
        case drawing(Annotation)
        case moving(UUID, from: CGPoint, to: CGPoint)
        case resizing(UUID, Annotation.Handle, to: CGPoint)
        case cropping(from: CGPoint, to: CGPoint)
        case restyling(Annotation)
        case highlightingText(from: TextLayout.Position, to: TextLayout.Position, Annotation)
    }

    public var tool: Tool = .arrow {
        didSet {
            onToolChange?(tool)
            updateCursorAtMouse()
        }
    }
    public var color: AnnotationColor = .red {
        didSet {
            if editingTextID == nil {
                textField?.textColor = color.nsColor
            }
        }
    }
    var activeResponder: NSResponder { textField ?? self }
    public var contentInsets = NSEdgeInsetsZero {
        didSet { needsDisplay = true }
    }
    public var onToolChange: ((Tool) -> Void)?
    public var onSelectionChange: (() -> Void)?
    public var onSave: (() -> Void)?
    public var onZoomChange: (() -> Void)?
    /// How far past fitting the window the capture is zoomed: 1 fits it, `maximumMagnification` shows it at `maximumZoom`.
    public private(set) var magnification: CGFloat = 1
    public private(set) var selectedID: UUID? {
        didSet {
            guard selectedID != oldValue else { return }
            needsDisplay = true
            updateAccessibilityValue()
            onSelectionChange?()
        }
    }

    let document: AnnotationDocument
    private let pixelsPerPoint: CGFloat
    private let lineWidth: CGFloat
    private let textLineHeight: CGFloat
    private var gesture: Gesture?
    private var textField: NSTextField?
    private var editingTextID: UUID?
    private var textFieldOrigin: CGPoint = .zero
    private var textFieldLineHeight: CGFloat = 0
    private var sliderLevels: [Tool: Double] = Dictionary(uniqueKeysWithValues: Tool.allCases.compactMap { tool in
        tool.sliderScale.map { (tool, $0.standard) }
    })
    /// The image point shown at the middle of the available rect, before `clamped(_:)` keeps the image covering it.
    private var focus: CGPoint

    /// Eight times the capture's real size: a pixel of a Retina capture spans 4 pt, wide enough to put a handle on.
    static let maximumZoom: CGFloat = 8
    // NSScrollView's default lineScroll: a mouse wheel reports lines, a trackpad points.
    private static let pointsPerLine: CGFloat = 10
    // A mouse-wheel notch, one line or 10 pt, zooms by e^0.1: about 10%.
    private static let zoomPerPoint: CGFloat = 0.01

    private static let handleDiameter: CGFloat = 10
    private static let arrowHandleDiameter: CGFloat = 14
    private static let haloWidth: CGFloat = 8
    private static let hitTolerance: CGFloat = 6
    // Same as ThumbnailView.dragThreshold: a click with a slight jitter draws nothing.
    private static let minimumDrag: CGFloat = 4

    public init(document: AnnotationDocument, pixelsPerPoint: CGFloat) {
        self.document = document
        self.pixelsPerPoint = pixelsPerPoint
        lineWidth = 3 * pixelsPerPoint
        textLineHeight = 28 * pixelsPerPoint
        focus = CGPoint(x: CGFloat(document.base.width) / 2, y: CGFloat(document.base.height) / 2)
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Annotation canvas")
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public func documentChanged() {
        if let selectedID, document.annotation(selectedID) == nil { self.selectedID = nil }
        if let editingTextID, let editing = document.annotation(editingTextID) {
            textField?.textColor = editing.color.nsColor
        }
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

    private var availableRect: CGRect {
        CGRect(
            x: contentInsets.left,
            y: contentInsets.top,
            width: bounds.width - contentInsets.left - contentInsets.right,
            height: bounds.height - contentInsets.top - contentInsets.bottom
        )
    }

    /// Fits the image, but never past its real size: a small capture blown up looks blurry and cheap.
    private var fitZoom: CGFloat {
        let available = availableRect
        let fit = min(available.width / imageSize.width, available.height / imageSize.height, 1 / pixelsPerPoint)
        return max(fit, .leastNormalMagnitude)
    }

    private var zoom: CGFloat { fitZoom * magnification }

    var maximumMagnification: CGFloat {
        max(Self.maximumZoom / pixelsPerPoint / fitZoom, 1)
    }

    /// The zoom as Preview shows it: 100% is the capture's real size.
    var zoomPercent: Int {
        Int((zoom * pixelsPerPoint * 100).rounded())
    }

    /// 0 fits the window, 1 is `maximumZoom`. Logarithmic, so every step of a slider zooms by the same ratio.
    var zoomPosition: Double {
        get {
            let range = log(maximumMagnification)
            return range > 0 ? Double(log(magnification) / range) : 0
        }
        set { setMagnification(pow(maximumMagnification, CGFloat(newValue))) }
    }

    var imageRect: CGRect {
        let available = availableRect
        let center = clamped(focus)
        return CGRect(
            x: available.midX - center.x * zoom,
            y: available.midY - center.y * zoom,
            width: imageSize.width * zoom,
            height: imageSize.height * zoom
        )
    }

    /// Centers an image smaller than the available rect; a bigger one may scroll only until its edge meets the rect's.
    private func clamped(_ point: CGPoint) -> CGPoint {
        let available = availableRect
        func axis(_ value: CGFloat, image: CGFloat, visible: CGFloat) -> CGFloat {
            let half = visible / 2 / zoom
            return image <= 2 * half ? image / 2 : min(max(value, half), image - half)
        }
        return CGPoint(
            x: axis(point.x, image: imageSize.width, visible: available.width),
            y: axis(point.y, image: imageSize.height, visible: available.height)
        )
    }

    /// The canvas reads as the image to accessibility, so its frame is the image's, not the backdrop's.
    public override func accessibilityFrame() -> NSRect {
        guard let window else { return super.accessibilityFrame() }
        return window.convertToScreen(convert(imageRect.intersection(bounds), to: nil))
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        magnification = min(magnification, maximumMagnification)
        zoomChanged()
    }

    // MARK: Zoom

    /// Keeps the image point under `anchor`, a point in the view, where it is; without one, the middle stays put.
    func setMagnification(_ value: CGFloat, anchoredAt anchor: CGPoint? = nil) {
        let available = availableRect
        let anchor = anchor ?? CGPoint(x: available.midX, y: available.midY)
        let before = imageRect
        let anchoredPoint = CGPoint(x: (anchor.x - before.minX) / zoom, y: (anchor.y - before.minY) / zoom)
        magnification = min(max(value, 1), maximumMagnification)
        focus = clamped(CGPoint(
            x: anchoredPoint.x - (anchor.x - available.midX) / zoom,
            y: anchoredPoint.y - (anchor.y - available.midY) / zoom
        ))
        zoomChanged()
    }

    /// Moves the image by `offset` view points, as a scroll view moves its content.
    func pan(by offset: CGSize) {
        let center = clamped(focus)
        focus = clamped(CGPoint(x: center.x - offset.width / zoom, y: center.y - offset.height / zoom))
        zoomChanged()
    }

    public override func scrollWheel(with event: NSEvent) {
        let points = event.hasPreciseScrollingDeltas ? 1 : Self.pointsPerLine
        let delta = CGSize(width: event.scrollingDeltaX * points, height: event.scrollingDeltaY * points)
        if event.modifierFlags.contains(.command) {
            setMagnification(magnification * exp(delta.height * Self.zoomPerPoint), anchoredAt: convert(event.locationInWindow, from: nil))
        } else if magnification > 1 {
            pan(by: delta)
        } else {
            super.scrollWheel(with: event)
        }
    }

    public override func magnify(with event: NSEvent) {
        setMagnification(magnification * (1 + event.magnification), anchoredAt: convert(event.locationInWindow, from: nil))
    }

    private func zoomChanged() {
        layoutTextField()
        needsDisplay = true
        onZoomChange?()
    }

    private func imagePoint(for event: NSEvent) -> CGPoint {
        imagePoint(atWindowPoint: event.locationInWindow)
    }

    private func imagePoint(atWindowPoint windowPoint: CGPoint) -> CGPoint {
        let p = convert(windowPoint, from: nil)
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
        case .drawing(let draft), .highlightingText(_, _, let draft):
            return document.annotations + [draft]
        case .moving(let id, let from, let to):
            return document.annotations.map { $0.id == id ? $0.moved(by: CGSize(width: to.x - from.x, height: to.y - from.y)) : $0 }
        case .resizing(let id, let handle, let to):
            return document.annotations.map { $0.id == id ? $0.resized(handle, to: to) : $0 }
        case .cropping:
            return document.annotations
        case .restyling(let restyled):
            return document.annotations.map { $0.id == restyled.id ? restyled : $0 }
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
        // Shadows ignore the CTM, so a negative height is down on screen. The shadow follows the image's alpha,
        // so a window capture without its wallpaper casts the window's shape, not a box.
        context.setShadow(offset: CGSize(width: 0, height: -6), blur: 24, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        context.draw(document.base, in: CGRect(origin: .zero, size: imageSize))
        context.restoreGState()
        if let selected = annotations.first(where: { $0.id == selectedID }), selected.kind == .arrow {
            drawHalo(behind: selected, in: context)
        }
        let visibleAnnotations = editingTextID == nil ? annotations : annotations.filter { $0.id != editingTextID }
        AnnotationRenderer.draw(visibleAnnotations, over: document.base, inFlippedContext: context, cache: document.renderCache)
        context.restoreGState()

        let edge = NSBezierPath(rect: imageRect.insetBy(dx: -0.5, dy: -0.5))
        edge.lineWidth = 1
        NSColor.labelColor.withAlphaComponent(0.1).setStroke()
        edge.stroke()

        if let crop = displayedCrop {
            drawCrop(crop)
        }

        if let selected = annotations.first(where: { $0.id == selectedID }) {
            drawSelection(of: selected)
        }
    }

    private func drawHalo(behind arrow: Annotation, in context: CGContext) {
        context.saveGState()
        context.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.45).cgColor)
        context.setLineWidth(arrow.lineWidth + Self.haloWidth / zoom)
        context.setLineCap(.round)
        context.addPath(arrow.curve)
        context.strokePath()
        context.restoreGState()
    }

    private func drawSelection(of annotation: Annotation) {
        guard annotation.kind != .arrow else { return drawArrowHandles(of: annotation) }
        let outline = NSBezierPath(rect: CGRect(origin: viewPoint(annotation.bounds.origin), size: CGSize(
            width: annotation.bounds.width * zoom, height: annotation.bounds.height * zoom
        )))
        outline.lineWidth = 1
        NSColor.controlAccentColor.setStroke()
        outline.stroke()
        let lift = NSShadow()
        lift.shadowColor = NSColor.black.withAlphaComponent(0.3)
        lift.shadowBlurRadius = 2
        lift.shadowOffset = NSSize(width: 0, height: -1)
        for handle in annotation.handles {
            let center = viewPoint(annotation.point(of: handle))
            let radius = Self.handleDiameter / 2
            let dot = NSBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius, width: Self.handleDiameter, height: Self.handleDiameter))
            NSGraphicsContext.saveGraphicsState()
            lift.set()
            NSColor.white.setFill()
            dot.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSColor.controlAccentColor.setStroke()
            dot.lineWidth = 1.5
            dot.stroke()
        }
    }

    private func drawArrowHandles(of arrow: Annotation) {
        let lift = NSShadow()
        lift.shadowColor = NSColor.black.withAlphaComponent(0.3)
        lift.shadowBlurRadius = 2
        lift.shadowOffset = NSSize(width: 0, height: -1)
        for handle in arrow.handles {
            let center = viewPoint(arrow.point(of: handle))
            let radius = Self.arrowHandleDiameter / 2
            let dot = NSBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
            NSGraphicsContext.saveGraphicsState()
            lift.set()
            (handle == .bend ? arrow.color.nsColor : NSColor.controlAccentColor).setFill()
            dot.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSColor.white.setStroke()
            dot.lineWidth = 2
            dot.stroke()
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

    // MARK: Slider

    /// What the dock slider adjusts: the selected arrow, blur or pixelate, else the next one the current tool draws.
    var sliderTarget: (tool: Tool, level: Double)? {
        if let selected = selectedSliding, let size = selected.annotation.sliderSize, let scale = selected.tool.sliderScale {
            return (selected.tool, scale.level(of: size, pixelsPerPoint: pixelsPerPoint))
        }
        guard let level = sliderLevels[tool] else { return nil }
        return (tool, level)
    }

    /// A selected arrow, blur or pixelate, unless the current tool draws another of the three.
    private var selectedSliding: (annotation: Annotation, tool: Tool)? {
        guard let selectedID, let annotation = document.annotation(selectedID),
              let owner = Tool(sliding: annotation.kind),
              sliderLevels[tool] == nil || tool == owner
        else { return nil }
        return (annotation, owner)
    }

    /// While the slider is dragged, only the canvas shows the change; `committing` writes it as one undo step.
    func setSliderLevel(_ level: Double, committing: Bool) {
        guard let target = sliderTarget, let scale = target.tool.sliderScale else { return }
        sliderLevels[target.tool] = level
        if let selected = selectedSliding?.annotation {
            let size = scale.size(at: level, pixelsPerPoint: pixelsPerPoint)
            if committing {
                gesture = nil
                document.setSliderSize(selected.id, size)
            } else {
                gesture = .restyling(selected.withSliderSize(size))
            }
        }
        needsDisplay = true
    }

    private func newAnnotationKind(for tool: Tool) -> Annotation.Kind? {
        switch tool {
        case .select, .text, .crop: nil
        case .arrow: .arrow
        case .rectangle: .rectangle
        case .highlighter: .highlighter
        case .blur: .blur(sigma: nextSliderSize(for: .blur))
        case .pixelate: .pixelate(block: nextSliderSize(for: .pixelate))
        }
    }

    private func nextSliderSize(for tool: Tool) -> CGFloat {
        guard let scale = tool.sliderScale else { return lineWidth }
        return scale.size(at: sliderLevels[tool] ?? scale.standard, pixelsPerPoint: pixelsPerPoint)
    }

    // MARK: Cursor

    public override func cursorUpdate(with event: NSEvent) {
        cursor(atWindowPoint: event.locationInWindow).set()
    }

    public override func mouseMoved(with event: NSEvent) {
        cursor(atWindowPoint: event.locationInWindow).set()
    }

    private func updateCursorAtMouse() {
        guard let window, window.isKeyWindow else { return }
        let location = window.mouseLocationOutsideOfEventStream
        guard bounds.contains(convert(location, from: nil)) else { return }
        cursor(atWindowPoint: location).set()
    }

    private func cursor(atWindowPoint windowPoint: CGPoint) -> NSCursor {
        if case .moving = gesture { return .closedHand }
        guard imageRect.contains(convert(windowPoint, from: nil)) else { return .arrow }
        let point = imagePoint(atWindowPoint: windowPoint)
        if let selectedID, let selected = document.annotation(selectedID),
           selected.handles.contains(where: { isNear(selected.point(of: $0), point) }) {
            return .crosshair
        }
        switch tool {
        case .select:
            return document.topmostAnnotation(at: point, tolerance: Self.hitTolerance / zoom) == nil ? .arrow : .openHand
        case .text:
            return .iBeam
        case .highlighter:
            return wordPosition(at: point) == nil ? .crosshair : .iBeam
        case .arrow, .rectangle, .blur, .pixelate, .crop:
            return .crosshair
        }
    }

    // MARK: Mouse

    public override func mouseDown(with event: NSEvent) {
        if textField != nil { endTextEditing(commit: true) }
        window?.makeFirstResponder(self)
        let point = imagePoint(for: event)
        let tolerance = Self.hitTolerance / zoom

        if event.clickCount == 2, let hit = document.topmostAnnotation(at: point, tolerance: tolerance), case .text = hit.kind {
            return beginTextEditing(hit)
        }
        if let selectedID, let selected = document.annotation(selectedID),
           let handle = selected.handles.first(where: { isNear(selected.point(of: $0), point) }) {
            gesture = .resizing(selectedID, handle, to: point)
            return
        }
        switch tool {
        case .select:
            selectedID = document.topmostAnnotation(at: point, tolerance: tolerance)?.id
            gesture = selectedID.map { .moving($0, from: point, to: point) }
            if gesture != nil { NSCursor.closedHand.set() }
        case .text:
            beginTextEntry(at: point)
        case .crop:
            selectedID = nil
            gesture = .cropping(from: point, to: point)
        case .highlighter where wordPosition(at: point) != nil:
            selectedID = nil
            let word = wordPosition(at: point)!
            gesture = .highlightingText(from: word, to: word, textHighlight(from: word, to: word, id: UUID()))
        case .arrow, .rectangle, .highlighter, .blur, .pixelate:
            selectedID = nil
            gesture = newAnnotationKind(for: tool).map {
                .drawing(Annotation(
                    kind: $0,
                    start: point,
                    end: point,
                    lineWidth: $0 == .arrow ? nextSliderSize(for: .arrow) : lineWidth,
                    color: color
                ))
            }
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
        case .highlightingText(let start, _, let draft):
            guard let end = document.textLayout?.nearestPosition(to: point) else { return }
            gesture = .highlightingText(from: start, to: end, textHighlight(from: start, to: end, id: draft.id))
        case .restyling: return
        }
        needsDisplay = true
    }

    public override func mouseUp(with event: NSEvent) {
        defer {
            gesture = nil
            needsDisplay = true
            cursor(atWindowPoint: event.locationInWindow).set()
        }
        switch gesture {
        case nil, .restyling:
            return
        case .drawing(let draft):
            guard hypot(draft.end.x - draft.start.x, draft.end.y - draft.start.y) * zoom >= Self.minimumDrag else { return }
            document.add(draft)
            selectedID = draft.id
        case .highlightingText(let start, let end, let draft):
            let point = imagePoint(for: event)
            if start == end, let existing = document.annotations.last(where: { $0.kind == .highlighter && $0.contains(point, tolerance: 0) }) {
                toggleHighlight(existing)
            } else {
                document.add(draft)
                selectedID = draft.id
            }
        case .moving(let id, let from, let to):
            document.move(id, by: CGSize(width: to.x - from.x, height: to.y - from.y))
        case .resizing(let id, let handle, let to):
            document.resize(id, handle, to: to)
        case .cropping(let from, let to):
            guard hypot(to.x - from.x, to.y - from.y) * zoom >= Self.minimumDrag, let crop = displayedCrop else { return }
            document.setCrop(crop)
        }
    }

    /// A click on a highlight in the picker's colour erases it; in any other colour, recolours it.
    private func toggleHighlight(_ highlight: Annotation) {
        if highlight.color == color {
            document.delete(highlight.id)
        } else {
            document.setColor(highlight.id, color)
            selectedID = highlight.id
        }
    }

    private func wordPosition(at point: CGPoint) -> TextLayout.Position? {
        document.textLayout?.position(at: point, pad: Self.hitTolerance / zoom)
    }

    private func textHighlight(from start: TextLayout.Position, to end: TextLayout.Position, id: UUID) -> Annotation {
        .textHighlight(document.textLayout?.highlight(from: start, to: end) ?? [], color: color, id: id)
    }

    private func isNear(_ handle: CGPoint, _ point: CGPoint) -> Bool {
        hypot(handle.x - point.x, handle.y - point.y) * zoom <= Self.handleDiameter
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

    static let shortcuts = Dictionary(uniqueKeysWithValues: Tool.allCases.map { ($0.shortcut, $0) })

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
        showTextField(at: point, text: "", lineHeight: textLineHeight, color: color)
    }

    private func beginTextEditing(_ annotation: Annotation) {
        guard case .text(let text) = annotation.kind else { return }
        selectedID = annotation.id
        editingTextID = annotation.id
        let lines = CGFloat(AnnotationRenderer.lineCount(text))
        showTextField(at: annotation.bounds.origin, text: text, lineHeight: annotation.bounds.height / lines, color: annotation.color)
    }

    private func showTextField(at imageOrigin: CGPoint, text: String, lineHeight: CGFloat, color: AnnotationColor) {
        let field = NSTextField(string: text)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = color.nsColor
        field.placeholderString = "Type, then press Return"
        field.delegate = self
        field.setAccessibilityLabel("Annotation text")
        addSubview(field)
        textField = field
        textFieldOrigin = imageOrigin
        textFieldLineHeight = lineHeight
        layoutTextField()
        window?.makeFirstResponder(field)
        needsDisplay = true
    }

    /// Text typed into a zoomed canvas grows and moves with the image under it.
    private func layoutTextField() {
        guard let field = textField else { return }
        field.font = AnnotationRenderer.textFont(fittingLineHeight: textFieldLineHeight * zoom)
        field.sizeToFit()
        field.frame = CGRect(origin: viewPoint(textFieldOrigin), size: CGSize(width: max(field.frame.width, 200), height: field.frame.height))
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
            let label = Annotation.text(text, at: textFieldOrigin, lineHeight: textFieldLineHeight, color: color)
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
