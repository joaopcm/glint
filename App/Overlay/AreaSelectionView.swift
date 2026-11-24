import AppKit
import GlintCore

final class AreaSelectionView: OverlayView {
    var selection: CGRect? {
        didSet { canvas.selection = selection }
    }
    var onSelectionChange: ((CGRect?) -> Void)?
    var onFinish: ((SelectionResult) -> Void)?

    private let backdrop: CGImage?
    private let canvas: SelectionCanvas
    private var dragOrigin: CGPoint?

    /// `backdrop` is the frozen grab of this screen; nil keeps the overlay see-through.
    init(screenFrame: CGRect, displays: [DisplayInfo], backdrop: CGImage? = nil) {
        self.backdrop = backdrop
        canvas = SelectionCanvas(screenFrame: screenFrame, displays: displays)
        super.init(screenFrame: screenFrame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        canvas.frame = bounds
        canvas.autoresizingMask = [.width, .height]
        addSubview(canvas)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.contents = backdrop
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func mouseDown(with event: NSEvent) {
        dragOrigin = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
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
