import AppKit

/// Liquid Glass on macOS 26, with the closest pre-26 material as a fallback (the app still targets macOS 15).
@MainActor
public enum Glass {
    public static let buttonSide: CGFloat = 28
    public static let toolbarHeight = buttonSide + 2 * toolbarInset
    public static let capsuleHeight: CGFloat = 22
    private static let toolbarInset: CGFloat = 2
    private static let titlePadding: CGFloat = 10
    private static let groupSpacing: CGFloat = 6

    /// `.behindWindow` blurs the desktop under a transparent panel; chrome floating over a window's own
    /// content needs `.withinWindow`. macOS 26 glass picks this itself.
    public static func background(
        cornerRadius: CGFloat,
        tint: NSColor? = nil,
        blending: NSVisualEffectView.BlendingMode = .behindWindow
    ) -> NSView {
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.tintColor = tint
            return glass
        }
        if let tint {
            let view = NSView()
            view.wantsLayer = true
            view.layer?.backgroundColor = tint.cgColor
            view.layer?.cornerRadius = cornerRadius
            view.layer?.cornerCurve = .continuous
            return view
        }
        let material = NSVisualEffectView()
        material.material = .hudWindow
        material.blendingMode = blending
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = cornerRadius
        material.layer?.cornerCurve = .continuous
        material.layer?.masksToBounds = true
        return material
    }

    public static func capsule(
        holding label: NSView,
        tint: NSColor? = nil,
        blending: NSVisualEffectView.BlendingMode = .behindWindow
    ) -> NSView {
        let content = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        let capsule = background(cornerRadius: capsuleHeight / 2, tint: tint, blending: blending)
        setContent(content, of: capsule)
        return capsule
    }

    public static func divider() -> NSView {
        let line = NSBox()
        line.boxType = .custom
        line.titlePosition = .noTitle
        line.borderWidth = 0
        line.fillColor = NSColor.labelColor.withAlphaComponent(0.15)
        line.widthAnchor.constraint(equalToConstant: 1).isActive = true
        line.heightAnchor.constraint(equalToConstant: 16).isActive = true
        return line
    }

    /// A capsule, or a circle around a single icon button. Icon buttons are `buttonSide` square, titled ones as wide
    /// as their title. The glass gets an explicit height: the stack's top and bottom insets don't size it, which left
    /// the close button 32x28 pt under a 16 pt radius (#91).
    public static func toolbar(
        _ items: [NSView],
        tint: NSColor? = nil,
        blending: NSVisualEffectView.BlendingMode = .behindWindow
    ) -> NSView {
        for case let button as NSButton in items {
            let width = button.imagePosition == .imageOnly ? buttonSide : ceil(button.intrinsicContentSize.width) + 2 * titlePadding
            button.widthAnchor.constraint(equalToConstant: width).isActive = true
            button.heightAnchor.constraint(equalToConstant: buttonSide).isActive = true
        }
        let stack = NSStackView(views: items)
        stack.spacing = 2
        for (index, item) in items.enumerated() where !(item is NSButton) {
            stack.setCustomSpacing(groupSpacing, after: item)
            if index > 0 { stack.setCustomSpacing(groupSpacing, after: items[index - 1]) }
        }
        let sideInset = items.count > 1 ? 6 : toolbarInset
        stack.edgeInsets = NSEdgeInsets(top: toolbarInset, left: sideInset, bottom: toolbarInset, right: sideInset)
        let background = background(cornerRadius: toolbarHeight / 2, tint: tint, blending: blending)
        setContent(stack, of: background)
        background.heightAnchor.constraint(equalToConstant: toolbarHeight).isActive = true
        return background
    }

    /// A rounded glass surface behind `content`, such as a floating panel's whole body.
    public static func surface(holding content: NSView, cornerRadius: CGFloat) -> NSView {
        let surface = background(cornerRadius: cornerRadius)
        setContent(content, of: surface)
        return surface
    }

    /// Only a glass view's `contentView` is guaranteed to render inside the glass.
    private static func setContent(_ content: NSView, of background: NSView) {
        content.translatesAutoresizingMaskIntoConstraints = false
        if #available(macOS 26, *), let glass = background as? NSGlassEffectView {
            glass.contentView = content
        } else {
            background.addSubview(content)
        }
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            content.topAnchor.constraint(equalTo: background.topAnchor),
            content.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
    }
}
