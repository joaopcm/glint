import AppKit

final class WindowPickerView: OverlayView {
    var highlight: CGRect? {
        didSet { needsDisplay = true }
    }
    var onPointerMove: ((CGPoint) -> Void)?
    var onClick: ((CGPoint) -> Void)?

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onPointerMove?(NSEvent.mouseLocation)
    }

    override func mouseDown(with event: NSEvent) {
        let point = NSEvent.mouseLocation
        onPointerMove?(point)
        onClick?(point)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let highlight else { return }
        let box = NSBezierPath(rect: local(highlight).insetBy(dx: 1, dy: 1))
        NSColor.systemBlue.withAlphaComponent(0.25).setFill()
        box.fill()
        NSColor.systemBlue.setStroke()
        box.lineWidth = 2
        box.stroke()
    }
}
