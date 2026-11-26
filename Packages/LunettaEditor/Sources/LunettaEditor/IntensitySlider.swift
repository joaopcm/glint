import AppKit

/// The dock's blur and pixelate intensity slider. It reports hovering like `GlassButton` does, and when a drag ends,
/// so the canvas can preview every step of the drag and keep one undo step for the whole of it.
@MainActor
final class IntensitySlider: NSSlider {
    var onHoverChange: ((_ hovered: Bool) -> Void)?
    var onTrackingEnd: (() -> Void)?
    private(set) var isTracking = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        if !isTracking { onHoverChange?(false) }
    }

    override func mouseDown(with event: NSEvent) {
        isTracking = true
        super.mouseDown(with: event) // tracks the drag until mouse up
        isTracking = false
        onTrackingEnd?()
        if let window, !bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
            onHoverChange?(false)
        }
    }
}
