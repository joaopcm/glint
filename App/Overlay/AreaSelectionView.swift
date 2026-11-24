import AppKit
import GlintCore

final class AreaSelectionView: OverlayView {
    var selection: CGRect? {
        didSet { canvas.selection = selection }
    }
    var onSelectionChange: ((CGRect?) -> Void)?
    var onFinish: ((SelectionResult) -> Void)?
    var onPointerMove: ((CGPoint) -> Void)?

    let display: DisplayInfo?
    private let backdrop: CGImage?
    private let canvas: SelectionCanvas
    private var dragOrigin: CGPoint?
    private let loupe = LoupeLayer()
    private let loupeElement = NSAccessibilityElement()

    /// `backdrop` is the frozen grab of this screen; nil keeps the overlay see-through.
    init(screenFrame: CGRect, display: DisplayInfo?, displays: [DisplayInfo], backdrop: CGImage? = nil) {
        self.display = display
        self.backdrop = backdrop
        canvas = SelectionCanvas(screenFrame: screenFrame, displays: displays)
        super.init(screenFrame: screenFrame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        canvas.frame = bounds
        canvas.autoresizingMask = [.width, .height]
        addSubview(canvas)
        layer?.addSublayer(loupe)
        loupeElement.setAccessibilityRole(.image)
        loupeElement.setAccessibilityLabel("Magnifier")
        loupeElement.setAccessibilityIdentifier(AccessibilityID.loupe)
        loupeElement.setAccessibilityParent(self)
        if let backdrop {
            setSnapshot(backdrop)
        }
    }

    /// Without a frozen backdrop, the controller grabs the screen after the overlay shows and hands it here.
    var needsSnapshot: Bool { !loupe.hasImage }

    func setSnapshot(_ image: CGImage) {
        loupe.setImage(image, scale: display?.scale ?? 1)
        updateLoupe(at: NSEvent.mouseLocation)
    }

    func updateLoupe(at pointer: CGPoint) {
        guard let display, loupe.hasImage, screenFrame.contains(pointer) else {
            loupe.hide()
            return
        }
        let frame = LoupeGeometry.frame(size: LoupeLayer.size, pointer: pointer, in: screenFrame, offset: LoupeLayer.pointerGap)
        loupe.show(pixel: LoupeGeometry.pixel(at: pointer, on: display), at: local(frame).origin)
        loupeElement.setAccessibilityFrame(frame)
    }

    override func accessibilityChildren() -> [Any]? {
        loupe.isHidden ? [] : [loupeElement]
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.contents = backdrop
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onPointerMove?(NSEvent.mouseLocation)
    }

    override func mouseDown(with event: NSEvent) {
        dragOrigin = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        onPointerMove?(NSEvent.mouseLocation)
        guard let dragOrigin else { return }
        onSelectionChange?(Self.rect(from: dragOrigin, to: NSEvent.mouseLocation))
    }

    override func mouseUp(with event: NSEvent) {
        guard let dragOrigin else { return }
        self.dragOrigin = nil
        let rect = Self.rect(from: dragOrigin, to: NSEvent.mouseLocation)
        onFinish?(rect.width >= 1 && rect.height >= 1 ? .area(rect) : .cancelled)
    }

    private static func rect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }
}

/// Draws the dimming, the selection outline and its size on top of the (possibly frozen) backdrop.
private final class SelectionCanvas: NSView {
    var selection: CGRect? {
        didSet { needsDisplay = true }
    }

    private let screenFrame: CGRect
    private let displays: [DisplayInfo]

    init(screenFrame: CGRect, displays: [DisplayInfo]) {
        self.screenFrame = screenFrame
        self.displays = displays
        super.init(frame: CGRect(origin: .zero, size: screenFrame.size))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSBezierPath(rect: bounds)
        dim.windingRule = .evenOdd
        if let selection {
            dim.appendRect(local(selection))
        }
        NSColor.black.withAlphaComponent(0.3).setFill()
        dim.fill()
        guard let selection else { return }
        NSColor.white.setStroke()
        NSBezierPath(rect: local(selection).insetBy(dx: -0.5, dy: -0.5)).stroke()
        drawPixelSize(of: selection)
    }

    private func drawPixelSize(of selection: CGRect) {
        guard let display = DisplayGeometry.display(forSelection: selection, in: displays),
              let sourceRect = DisplayGeometry.sourceRect(for: selection, on: display)
        else { return }
        let size = DisplayGeometry.pixelSize(of: sourceRect, scale: display.scale)
        let label = NSAttributedString(string: "\(size.width) × \(size.height)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ])
        let padding = CGSize(width: 6, height: 3)
        let labelSize = label.size()
        let boxSize = CGSize(width: labelSize.width + padding.width * 2, height: labelSize.height + padding.height * 2)
        let gap: CGFloat = 6
        let below = selection.minY - gap - boxSize.height
        let fitsBelow = display.frame.minY <= below
        let origin = CGPoint(x: selection.minX, y: fitsBelow ? below : selection.minY + gap)
        let box = local(CGRect(origin: origin, size: boxSize))
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        label.draw(at: CGPoint(x: box.minX + padding.width, y: box.minY + padding.height))
    }

    private func local(_ globalRect: CGRect) -> CGRect {
        globalRect.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
    }
}
