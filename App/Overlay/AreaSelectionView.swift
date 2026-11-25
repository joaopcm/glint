import AppKit
import GlintCore

final class AreaSelectionView: OverlayView {
    private static let dimColor = NSColor.black.withAlphaComponent(0.3).cgColor
    private static let badgeColor = NSColor.black.withAlphaComponent(0.75).cgColor
    private static let sizeFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)

    var selection: CGRect? {
        didSet {
            guard selection != oldValue else { return }
            updateSelectionLayers()
        }
    }
    var onSelectionChange: ((CGRect?) -> Void)?
    var onFinish: ((SelectionResult) -> Void)?
    var onPointerMove: ((CGPoint) -> Void)?

    let display: DisplayInfo?
    private let displays: [DisplayInfo]
    private let backdrop: CGImage?
    private let topDim = CALayer()
    private let bottomDim = CALayer()
    private let leftDim = CALayer()
    private let rightDim = CALayer()
    private let selectionBorder = CALayer()
    private let sizeBadge = CALayer()
    private let sizeLabel = CATextLayer()
    private var lastPixelSize: (width: Int, height: Int)?
    private var cachedLabelSize = CGSize.zero
    private var dragOrigin: CGPoint?
    private let loupe: LoupeLayer?
    private let loupeElement = NSAccessibilityElement()
    private var lastLoupeFrame = CGRect.null

    /// `backdrop` is the frozen grab of this screen; nil keeps the overlay see-through.
    init(screenFrame: CGRect, display: DisplayInfo?, displays: [DisplayInfo], showsLoupe: Bool, backdrop: CGImage? = nil) {
        self.display = display
        self.displays = displays
        self.backdrop = backdrop
        loupe = showsLoupe ? LoupeLayer() : nil
        super.init(screenFrame: screenFrame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never

        for dim in [topDim, bottomDim, leftDim, rightDim] {
            dim.backgroundColor = Self.dimColor
            layer?.addSublayer(dim)
        }

        selectionBorder.borderWidth = 1
        selectionBorder.borderColor = NSColor.white.cgColor
        selectionBorder.isHidden = true
        layer?.addSublayer(selectionBorder)

        sizeBadge.backgroundColor = Self.badgeColor
        sizeBadge.cornerRadius = 4
        sizeBadge.cornerCurve = .continuous
        sizeBadge.isHidden = true

        sizeLabel.font = Self.sizeFont
        sizeLabel.fontSize = 12
        sizeLabel.foregroundColor = NSColor.white.cgColor
        sizeLabel.contentsScale = display?.scale ?? 2
        sizeBadge.addSublayer(sizeLabel)
        layer?.addSublayer(sizeBadge)

        if let loupe {
            layer?.addSublayer(loupe)
        }
        updateSelectionLayers()

        loupeElement.setAccessibilityRole(.image)
        loupeElement.setAccessibilityLabel("Magnifier")
        loupeElement.setAccessibilityIdentifier(AccessibilityID.loupe)
        loupeElement.setAccessibilityParent(self)
        if let backdrop {
            setSnapshot(backdrop)
        }
    }

    /// Without a frozen backdrop, the controller grabs the screen after the overlay shows and hands it here.
    var needsSnapshot: Bool { loupe?.hasImage == false }

    func setSnapshot(_ image: CGImage) {
        guard let loupe else { return }
        loupe.setImage(image, scale: display?.scale ?? 1)
        updateLoupe(at: NSEvent.mouseLocation)
    }

    func updateLoupe(at pointer: CGPoint) {
        guard let loupe else { return }
        guard let display, loupe.hasImage, screenFrame.contains(pointer) else {
            loupe.hide()
            return
        }
        let frame = LoupeGeometry.frame(size: LoupeLayer.size, pointer: pointer, in: screenFrame, offset: LoupeLayer.pointerGap)
        loupe.show(pixel: LoupeGeometry.pixel(at: pointer, on: display), at: local(frame).origin)
        if frame != lastLoupeFrame {
            lastLoupeFrame = frame
            loupeElement.setAccessibilityFrame(frame)
        }
    }

    override func accessibilityChildren() -> [Any]? {
        loupe?.isHidden == false ? [loupeElement] : []
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
        onPointerMove?(event.screenLocation)
    }

    override func mouseDown(with event: NSEvent) {
        dragOrigin = event.screenLocation
    }

    override func mouseDragged(with event: NSEvent) {
        onPointerMove?(event.screenLocation)
        guard let dragOrigin else { return }
        onSelectionChange?(Self.rect(from: dragOrigin, to: event.screenLocation))
    }

    override func mouseUp(with event: NSEvent) {
        guard let dragOrigin else { return }
        self.dragOrigin = nil
        let rect = Self.rect(from: dragOrigin, to: event.screenLocation)
        onFinish?(rect.width >= 1 && rect.height >= 1 ? .area(rect) : .cancelled)
    }

    private static func rect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    private func updateSelectionLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let viewBounds = bounds
        guard let selection else {
            topDim.frame = viewBounds
            topDim.isHidden = false
            bottomDim.isHidden = true
            leftDim.isHidden = true
            rightDim.isHidden = true
            selectionBorder.isHidden = true
            sizeBadge.isHidden = true
            return
        }

        let localSelection = local(selection)
        let clipped = localSelection.intersection(viewBounds)
        if clipped.isNull || clipped.isEmpty {
            topDim.frame = viewBounds
            topDim.isHidden = false
            bottomDim.isHidden = true
            leftDim.isHidden = true
            rightDim.isHidden = true
        } else {
            setStrip(topDim, CGRect(x: 0, y: clipped.maxY, width: viewBounds.width, height: viewBounds.maxY - clipped.maxY))
            setStrip(bottomDim, CGRect(x: 0, y: 0, width: viewBounds.width, height: clipped.minY))
            setStrip(leftDim, CGRect(x: 0, y: clipped.minY, width: clipped.minX, height: clipped.height))
            setStrip(rightDim, CGRect(x: clipped.maxX, y: clipped.minY, width: viewBounds.maxX - clipped.maxX, height: clipped.height))
        }

        let borderFrame = localSelection.insetBy(dx: -1, dy: -1)
        if borderFrame.intersects(viewBounds) {
            selectionBorder.frame = borderFrame
            selectionBorder.isHidden = false
        } else {
            selectionBorder.isHidden = true
        }

        updateSizeBadge(for: selection, in: viewBounds)
    }

    private func setStrip(_ layer: CALayer, _ rect: CGRect) {
        if rect.width > 0, rect.height > 0 {
            layer.frame = rect
            layer.isHidden = false
        } else {
            layer.isHidden = true
        }
    }

    private func updateSizeBadge(for selection: CGRect, in viewBounds: CGRect) {
        guard let display = DisplayGeometry.display(forSelection: selection, in: displays),
              let sourceRect = DisplayGeometry.sourceRect(for: selection, on: display)
        else {
            sizeBadge.isHidden = true
            return
        }
        let size = DisplayGeometry.pixelSize(of: sourceRect, scale: display.scale)
        if lastPixelSize?.width != size.width || lastPixelSize?.height != size.height {
            lastPixelSize = size
            let text = "\(size.width) × \(size.height)"
            let measured = (text as NSString).size(withAttributes: [.font: Self.sizeFont])
            cachedLabelSize = CGSize(width: ceil(measured.width), height: ceil(measured.height))
            sizeLabel.string = text
        }
        let padding = CGSize(width: 6, height: 3)
        let boxSize = CGSize(width: cachedLabelSize.width + padding.width * 2, height: cachedLabelSize.height + padding.height * 2)
        let gap: CGFloat = 6
        let below = selection.minY - gap - boxSize.height
        let fitsBelow = display.frame.minY <= below
        let origin = CGPoint(x: selection.minX, y: fitsBelow ? below : selection.minY + gap)
        let box = local(CGRect(origin: origin, size: boxSize))
        if box.intersects(viewBounds) {
            sizeBadge.frame = box
            sizeLabel.frame = CGRect(origin: CGPoint(x: padding.width, y: padding.height), size: cachedLabelSize)
            sizeBadge.isHidden = false
        } else {
            sizeBadge.isHidden = true
        }
    }
}
