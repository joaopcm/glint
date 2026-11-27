import AppKit
import LunettaUI

/// A dock slider that reports hovering like `GlassButton` does, and when a drag ends, so the canvas can preview every
/// step of the drag and keep one undo step for the whole of it.
@MainActor
final class DockSlider: NSSlider {
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

/// A `DockSlider` in the tools bar that slides out next to the buttons of the tools it adjusts, and closes to nothing
/// for every other tool.
@MainActor
final class SliderDrawer {
    /// Which side of the buttons it adjusts the drawer sits on.
    enum Side {
        case before, after
    }

    // The open dock still has to fit the minimum window: `anOpenSliderFitsTheSmallestWindow` trips first.
    static let sliderWidth: CGFloat = 88
    static let inset: CGFloat = 6
    static let openWidth = inset + sliderWidth

    let slider = DockSlider()
    let host = NSView()
    let tools: Set<EditorCanvas.Tool>
    /// What the slider sets, as the caption and VoiceOver name it after the tool: "Blur intensity", "Arrow thickness".
    let quantity: String
    let side: Side
    private(set) var isOpen = false
    private var hostWidth: NSLayoutConstraint!

    init(tools: Set<EditorCanvas.Tool>, quantity: String, side: Side) {
        self.tools = tools
        self.quantity = quantity
        self.side = side
        slider.minValue = 0
        slider.maxValue = 1
        slider.isContinuous = true
        slider.controlSize = .small
        slider.alphaValue = 0
        slider.isHidden = true
        slider.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(slider)
        host.clipsToBounds = true
        hostWidth = host.widthAnchor.constraint(equalToConstant: 0)
        // The inset sits on the side away from the buttons, so the slider slides out from under them.
        let edge = side == .after
            ? slider.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: Self.inset)
            : slider.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -Self.inset)
        NSLayoutConstraint.activate([
            hostWidth,
            host.heightAnchor.constraint(equalToConstant: Glass.buttonSide),
            edge,
            slider.widthAnchor.constraint(equalToConstant: Self.sliderWidth),
            slider.centerYAnchor.constraint(equalTo: host.centerYAnchor),
        ])
    }

    /// How far the dock's center moves so the buttons on the drawer's far side stay put while it opens, keeping the
    /// button that opened it under the pointer.
    var dockOffset: CGFloat {
        guard isOpen else { return 0 }
        return side == .after ? Self.openWidth / 2 : -Self.openWidth / 2
    }

    /// Starts opening or closing; `show(animated:)` then moves it there.
    func setOpen(_ open: Bool) {
        isOpen = open
        slider.isHidden = false
    }

    func show(animated: Bool) {
        let width = isOpen ? Self.openWidth : 0
        let alpha: CGFloat = isOpen ? 1 : 0
        guard animated else {
            hostWidth.constant = width
            slider.alphaValue = alpha
            slider.isHidden = !isOpen
            return
        }
        hostWidth.animator().constant = width
        slider.animator().alphaValue = alpha
    }

    /// Hidden once closed, so VoiceOver doesn't find a slider clipped to nothing; reopening mid-close wins.
    func hideIfClosed() {
        if !isOpen { slider.isHidden = true }
    }
}
