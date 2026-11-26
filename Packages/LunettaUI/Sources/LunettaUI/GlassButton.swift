import AppKit

/// The round, borderless button that sits in a `Glass.toolbar`. A toggle (`.pushOnPushOff`) fills with the accent
/// color while on. The tracking area is `.activeAlways`: Lunetta is never the active app while a card is up.
@MainActor
public final class GlassButton: NSButton {
    public var onHoverChange: ((GlassButton, _ hovered: Bool) -> Void)?
    public var tint: NSColor = .labelColor {
        didSet { applyTint() }
    }
    private var isHovered = false {
        didSet { needsDisplay = true }
    }
    private var isPressed = false {
        didSet { needsDisplay = true }
    }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        applyTint()
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var state: NSControl.StateValue {
        didSet { applyTint() }
    }

    public override var isEnabled: Bool {
        didSet { needsDisplay = true }
    }

    /// Non-activating panels never become key; without this the first click on a button is eaten.
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// AppKit's insets are uneven (2.5 top, 1.5 bottom, 0.5 right on macOS 27), which turned the hover circle into an oval.
    public override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    public override func setButtonType(_ type: NSButton.ButtonType) {
        super.setButtonType(type)
        // The fill shows the state; the cell's own on-state look would draw over it.
        (cell as? NSButtonCell)?.showsStateBy = []
    }

    public override func mouseEntered(with event: NSEvent) {
        isHovered = true
        onHoverChange?(self, true)
    }

    public override func mouseExited(with event: NSEvent) {
        isHovered = false
        onHoverChange?(self, false)
    }

    public override func mouseDown(with event: NSEvent) {
        isPressed = true
        display()
        super.mouseDown(with: event) // tracks the click until mouse up
        isPressed = false
    }

    public override func draw(_ dirtyRect: NSRect) {
        let radius = min(bounds.width, bounds.height) / 2
        let shape = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        if state == .on {
            NSColor.controlAccentColor.withAlphaComponent(isPressed ? 0.8 : 1).setFill()
            shape.fill()
        } else if isEnabled, isHovered || isPressed {
            tint.withAlphaComponent(isPressed ? 0.2 : 0.1).setFill()
            shape.fill()
        }
        super.draw(dirtyRect)
    }

    private func applyTint() {
        contentTintColor = state == .on ? .white : tint
        needsDisplay = true
    }
}
