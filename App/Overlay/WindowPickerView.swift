import AppKit

final class WindowPickerView: OverlayView {
    private static let fillColor = NSColor.systemBlue.withAlphaComponent(0.25).cgColor
    private static let strokeColor = NSColor.systemBlue.cgColor

    var highlight: CGRect? {
        didSet {
            guard highlight != oldValue else { return }
            updateHighlightLayer()
        }
    }
    var onPointerMove: ((CGPoint) -> Void)?
    var onClick: ((CGPoint) -> Void)?

    private let highlightLayer = CALayer()

    override init(screenFrame: CGRect) {
        super.init(screenFrame: screenFrame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        highlightLayer.backgroundColor = Self.fillColor
        highlightLayer.borderColor = Self.strokeColor
        highlightLayer.borderWidth = 2
        highlightLayer.isHidden = true
        layer?.addSublayer(highlightLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {}

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onPointerMove?(event.screenLocation)
    }

    override func mouseDown(with event: NSEvent) {
        let point = event.screenLocation
        onPointerMove?(point)
        onClick?(point)
    }

    private func updateHighlightLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let highlight else {
            highlightLayer.isHidden = true
            return
        }
        let rect = local(highlight)
        if rect.intersects(bounds) {
            highlightLayer.frame = rect
            highlightLayer.isHidden = false
        } else {
            highlightLayer.isHidden = true
        }
    }
}
