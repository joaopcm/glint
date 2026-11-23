import AppKit
import GlintCore

final class AreaSelectionView: OverlayView {
    var selection: CGRect? {
        didSet { needsDisplay = true }
    }
    var onSelectionChange: ((CGRect?) -> Void)?
    var onFinish: ((SelectionResult) -> Void)?

    private let displays: [DisplayInfo]
    private var dragOrigin: CGPoint?

    init(screenFrame: CGRect, displays: [DisplayInfo]) {
        self.displays = displays
        super.init(screenFrame: screenFrame)
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
        let size = DisplayGeometry.pixelSize(of: sourceRect, on: display)
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

    private static func rect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }
}
