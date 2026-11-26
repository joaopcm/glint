import AppKit
import LunettaUI
import QuartzCore

@MainActor
final class ColorPickerButton: NSButton {
    static let chevronSymbol = "chevron.up"
    private static let swatchDiameter: CGFloat = 18
    private static let leadingInset: CGFloat = 6
    private static let chevronRightInset: CGFloat = 8

    var onHoverChange: ((NSView, _ hovered: Bool) -> Void)?
    var color: AnnotationColor = .red {
        didSet {
            guard color != oldValue else { return }
            setAccessibilityValue(color.accessibilityName)
            needsDisplay = true
        }
    }
    var isOpen = false {
        didSet {
            guard isOpen != oldValue else { return }
            needsDisplay = true
        }
    }
    private var isHovered = false {
        didSet { needsDisplay = true }
    }
    private var isPressed = false {
        didSet { needsDisplay = true }
    }

    init(target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        title = ""
        isBordered = false
        imagePosition = .noImage
        setAccessibilityLabel("Color")
        setAccessibilityValue(color.accessibilityName)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// `Glass.toolbar` adds `2 * 10 pt` horizontal padding to non-`imageOnly` buttons, yielding a 48×28 pt pill.
    override var intrinsicContentSize: NSSize {
        NSSize(width: Glass.buttonSide, height: Glass.buttonSide)
    }

    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        onHoverChange?(self, true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        onHoverChange?(self, false)
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        display()
        super.mouseDown(with: event)
        isPressed = false
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = min(bounds.width, bounds.height) / 2
        if isOpen || isHovered || isPressed {
            let alpha: CGFloat = isPressed ? 0.2 : (isOpen ? 0.14 : 0.1)
            NSColor.labelColor.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        }

        let swatchRect = CGRect(
            x: Self.leadingInset,
            y: (bounds.height - Self.swatchDiameter) / 2,
            width: Self.swatchDiameter,
            height: Self.swatchDiameter
        )
        drawSwatchCircle(color: color, in: swatchRect)

        let symbol = NSImage(systemSymbolName: Self.chevronSymbol, accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))!
        let tinted = symbol.tinted(with: isOpen || isHovered ? .labelColor : .secondaryLabelColor)
        let size = tinted.size
        let chevronOrigin = CGPoint(
            x: bounds.maxX - Self.chevronRightInset - size.width,
            y: (bounds.height - size.height) / 2
        )
        tinted.draw(in: CGRect(origin: chevronOrigin, size: size))
    }
}

@MainActor
final class SwatchButton: NSButton {
    enum Style {
        case solid(AnnotationColor)
        case rainbow
    }

    static let hitSize: CGFloat = 30
    private static let swatchDiameter: CGFloat = 22
    private static let ringDiameter: CGFloat = 28
    private static let ringLineWidth: CGFloat = 2.5

    let style: Style
    var ringColor: AnnotationColor = .red {
        didSet { needsDisplay = true }
    }
    private var isHovered = false {
        didSet { needsDisplay = true }
    }
    private var isPressed = false {
        didSet { needsDisplay = true }
    }

    init(style: Style, label: String, target: AnyObject?, action: Selector?) {
        self.style = style
        super.init(frame: CGRect(x: 0, y: 0, width: Self.hitSize, height: Self.hitSize))
        self.target = target
        self.action = action
        title = ""
        isBordered = false
        setButtonType(.pushOnPushOff)
        (cell as? NSButtonCell)?.showsStateBy = []
        setAccessibilityLabel(label)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.hitSize),
            heightAnchor.constraint(equalToConstant: Self.hitSize),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        display()
        super.mouseDown(with: event)
        isPressed = false
    }

    override func draw(_ dirtyRect: NSRect) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        if state == .on || isHovered {
            let ringRect = CGRect(
                x: center.x - Self.ringDiameter / 2,
                y: center.y - Self.ringDiameter / 2,
                width: Self.ringDiameter,
                height: Self.ringDiameter
            )
            let ring = NSBezierPath(ovalIn: ringRect)
            ring.lineWidth = Self.ringLineWidth
            if state == .on {
                selectionRingColor(for: ringColor).setStroke()
            } else {
                NSColor.labelColor.withAlphaComponent(0.16).setStroke()
            }
            ring.stroke()
        }

        let diameter = isPressed ? Self.swatchDiameter - 1.5 : Self.swatchDiameter
        let swatchRect = CGRect(
            x: center.x - diameter / 2,
            y: center.y - diameter / 2,
            width: diameter,
            height: diameter
        )
        switch style {
        case .solid(let color):
            drawSwatchCircle(color: color, in: swatchRect)
        case .rainbow:
            drawRainbowWheel(in: swatchRect)
        }
    }

    private func selectionRingColor(for color: AnnotationColor) -> NSColor {
        let lum = color.relativeLuminance
        if lum > 0.85 || lum < 0.08 {
            return NSColor.labelColor.withAlphaComponent(0.32)
        }
        return color.nsColor.withAlphaComponent(0.4)
    }
}

@MainActor
final class ColorPalettePanel: NSPanel {
    static let width: CGFloat = 42
    private static let verticalInset: CGFloat = 8
    private static let itemSpacing: CGFloat = 2
    private static let dividerSpacing: CGFloat = 5
    private static let dividerWidth: CGFloat = 12

    let onSelectColor: (AnnotationColor) -> Void
    let onSelectCustom: () -> Void
    private(set) var presetButtons: [AnnotationColor: SwatchButton] = [:]
    private(set) var customButton: SwatchButton!

    var selectedColor: AnnotationColor {
        didSet { syncSelection() }
    }

    init(
        selectedColor: AnnotationColor,
        onSelectColor: @escaping (AnnotationColor) -> Void,
        onSelectCustom: @escaping () -> Void
    ) {
        self.selectedColor = selectedColor
        self.onSelectColor = onSelectColor
        self.onSelectCustom = onSelectCustom
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        setAccessibilityLabel("Color palette")

        let content = buildContent()
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        setContentSize(size)
        contentView = content
        syncSelection()
    }

    private func buildContent() -> NSView {
        var rows: [NSView] = []
        for (index, preset) in AnnotationColor.presets.enumerated() {
            let button = SwatchButton(
                style: .solid(preset.color),
                label: preset.name,
                target: self,
                action: #selector(choosePreset(_:))
            )
            button.tag = index
            button.ringColor = preset.color
            presetButtons[preset.color] = button
            rows.append(button)
        }

        let divider = NSBox()
        divider.boxType = .custom
        divider.titlePosition = .noTitle
        divider.borderWidth = 0
        divider.fillColor = NSColor.labelColor.withAlphaComponent(0.15)
        divider.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            divider.widthAnchor.constraint(equalToConstant: Self.dividerWidth),
            divider.heightAnchor.constraint(equalToConstant: 1),
        ])
        rows.append(divider)

        let rainbow = SwatchButton(
            style: .rainbow,
            label: "Custom Color…",
            target: self,
            action: #selector(chooseCustom)
        )
        customButton = rainbow
        rows.append(rainbow)

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Self.itemSpacing
        if let lastPreset = rows.dropLast(2).last {
            stack.setCustomSpacing(Self.dividerSpacing, after: lastPreset)
        }
        stack.setCustomSpacing(Self.dividerSpacing, after: divider)
        stack.edgeInsets = NSEdgeInsets(top: Self.verticalInset, left: 0, bottom: Self.verticalInset, right: 0)

        let surface = Glass.surface(holding: stack, cornerRadius: Self.width / 2)
        surface.translatesAutoresizingMaskIntoConstraints = false
        surface.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        return surface
    }

    private func syncSelection() {
        let matchesPreset = presetButtons[selectedColor] != nil
        for (color, button) in presetButtons {
            button.state = color == selectedColor ? .on : .off
        }
        customButton.ringColor = selectedColor
        customButton.state = matchesPreset ? .off : .on
    }

    @objc private func choosePreset(_ sender: NSButton) {
        let color = AnnotationColor.presets[sender.tag].color
        onSelectColor(color)
    }

    @objc private func chooseCustom() {
        onSelectCustom()
    }
}

@MainActor
private func drawSwatchCircle(color: AnnotationColor, in rect: CGRect) {
    let circle = NSBezierPath(ovalIn: rect)
    color.nsColor.setFill()
    circle.fill()

    let borderAlpha: CGFloat = color.relativeLuminance > 0.85 ? 0.22 : 0.12
    let border = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
    border.lineWidth = 1
    NSColor.labelColor.withAlphaComponent(borderAlpha).setStroke()
    border.stroke()
}

@MainActor
private func drawRainbowWheel(in rect: CGRect) {
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(ovalIn: rect).addClip()
    if let cgContext = NSGraphicsContext.current?.cgContext {
        cgContext.draw(rainbowWheelBitmap, in: rect)
    }
    NSGraphicsContext.restoreGraphicsState()

    let border = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
    border.lineWidth = 1
    NSColor.labelColor.withAlphaComponent(0.15).setStroke()
    border.stroke()
}

/// 64×64 px (> 2× the 22 pt swatch on Retina) renders once in < 0.1 ms with zero wedge seams.
private let rainbowWheelBitmap: CGImage = {
    let side = 64
    var pixels = [UInt8](repeating: 255, count: side * side * 4)
    let center = Double(side - 1) / 2
    let radius = Double(side) / 2
    for y in 0..<side {
        for x in 0..<side {
            let dx = Double(x) - center
            let dy = center - Double(y)
            let rawHue = atan2(dy, dx) / (2 * .pi)
            let hue = rawHue < 0 ? rawHue + 1 : rawHue
            let saturation = min(hypot(dx, dy) / radius, 1)
            let sector = hue * 6
            let index = Int(sector.rounded(.down))
            let fraction = sector - Double(index)
            let p = 1 - saturation
            let q = 1 - saturation * fraction
            let t = 1 - saturation * (1 - fraction)
            let (r, g, b): (Double, Double, Double) = switch index % 6 {
            case 0: (1, t, p)
            case 1: (q, 1, p)
            case 2: (p, 1, t)
            case 3: (p, q, 1)
            case 4: (t, p, 1)
            default: (1, p, q)
            }
            let offset = (y * side + x) * 4
            pixels[offset] = UInt8((r * 255).rounded())
            pixels[offset + 1] = UInt8((g * 255).rounded())
            pixels[offset + 2] = UInt8((b * 255).rounded())
        }
    }
    let context = CGContext(
        data: &pixels,
        width: side,
        height: side,
        bitsPerComponent: 8,
        bytesPerRow: side * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    return context.makeImage()!
}()

private extension NSImage {
    func tinted(with color: NSColor) -> NSImage {
        let copy = copy() as! NSImage
        copy.lockFocus()
        color.set()
        CGRect(origin: .zero, size: copy.size).fill(using: .sourceAtop)
        copy.unlockFocus()
        copy.isTemplate = false
        return copy
    }
}
