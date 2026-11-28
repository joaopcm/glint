import AppKit
import KeyboardShortcuts
import LunettaCapture
import LunettaCore
import LunettaUI

/// An outline the pointer goes through, so the page under the area keeps scrolling, and a panel with the preview and
/// Done and Cancel that never takes the keyboard from that page.
@MainActor
final class ScrollingStage: ScrollStaging {
    /// Six lines of 13 pt text at its 16 pt line height: enough to watch the newest rows join.
    static let previewHeight: CGFloat = 96

    private(set) var windows: [NSWindow] = []
    private(set) var heightText = ""
    private(set) var statusText: String?
    private var controls: ScrollingControlsView?
    private var area: CGRect = .zero
    private var visibleFrame: CGRect = .zero
    private var scale: CGFloat = 1
    private var outcome: ScrollStageDecision? = .cancelled
    private var waiting: CheckedContinuation<ScrollStageDecision, Never>?

    var previewPixelHeight: Int { Int((Self.previewHeight * scale).rounded()) }

    static func status(for state: StitchUpdate.State) -> String? {
        switch state {
        case .tracking: nil
        case .lostOverlap: "Scroll back — lost the overlap"
        case .heightLimitReached(let limit): "Height limit \(limit) px reached"
        }
    }

    static func heightLabel(pixels: Int, scale: CGFloat) -> String {
        "\(Int((CGFloat(pixels) / scale).rounded())) pt"
    }

    func prepare(_ area: CGRect, on display: DisplayInfo) {
        if outcome == nil { decide(.cancelled) }
        outcome = nil
        self.area = area
        scale = display.scale
        visibleFrame = NSScreen.screens.first { $0.frame == display.frame }?.visibleFrame ?? display.frame
        heightText = Self.heightLabel(pixels: Int((area.height * scale).rounded()), scale: scale)
        statusText = nil

        let controls = ScrollingControlsView(
            previewWidth: min(area.width, visibleFrame.width - 2 * ScrollingControlsView.gap),
            onFinish: { [weak self] in self?.finish() },
            onCancel: { [weak self] in self?.cancel() }
        )
        controls.render(height: heightText, status: statusText)
        let outline = StageOutlineWindow(frame: display.frame, area: area, scale: display.scale)
        let panel = ScrollingControlsPanel(content: controls)
        self.controls = controls
        windows = [outline, panel]
        place(panel)
        outline.orderFrontRegardless()
        panel.orderFrontRegardless()
        KeyboardShortcuts.onKeyDown(for: .finishScrollingCapture) { [weak self] in self?.finish() }
        KeyboardShortcuts.onKeyDown(for: .cancelScrollingCapture) { [weak self] in self?.cancel() }
    }

    func decision() async -> ScrollStageDecision {
        if let outcome { return outcome }
        return await withCheckedContinuation { waiting = $0 }
    }

    func show(_ update: StitchUpdate, preview: CGImage?) {
        guard outcome == nil, let controls, let panel = windows.last else { return }
        let height = Self.heightLabel(pixels: update.height, scale: scale)
        let status = Self.status(for: update.state)
        let statusChanged = status != statusText
        heightText = height
        statusText = status
        controls.render(height: height, status: status)
        if let preview { controls.showPreview(preview, scale: scale) }
        if statusChanged { place(panel) }
    }

    func dismiss() {
        decide(.cancelled)
    }

    func finish() {
        decide(.done)
    }

    func cancel() {
        decide(.cancelled)
    }

    private func place(_ panel: NSWindow) {
        guard let controls else { return }
        let size = Glass.fittingSize(of: controls.surface)
        let frame = RecordingGeometry.controlBarFrame(size: size, region: area, visible: visibleFrame, gap: ScrollingControlsView.gap)
        panel.setFrame(frame, display: true)
    }

    /// Windows go out here, before `decision()` returns: Done before the first frame takes an area capture right
    /// away, and `CaptureChrome` only hides windows that still exist.
    private func decide(_ decision: ScrollStageDecision) {
        guard outcome == nil else { return }
        outcome = decision
        KeyboardShortcuts.removeHandler(for: .finishScrollingCapture)
        KeyboardShortcuts.removeHandler(for: .cancelScrollingCapture)
        for window in windows { window.orderOut(nil) }
        windows = []
        controls = nil
        let waiting = waiting
        self.waiting = nil
        waiting?.resume(returning: decision)
    }
}

private final class StageOutlineWindow: NSWindow {
    convenience init(frame: CGRect, area: CGRect, scale: CGFloat) {
        self.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        CaptureChrome.mark(self)
        level = ScrollingControlsPanel.stageLevel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        animationBehavior = .none
        isReleasedWhenClosed = false
        contentView = StageOutlineView(size: frame.size, hole: area.offsetBy(dx: -frame.minX, dy: -frame.minY), scale: scale)
        setFrame(frame, display: false)
    }
}

/// The recording stage's dim and edge (`RecordingStageView`), without its grips: a scrolling area can't change.
private final class StageOutlineView: NSView {
    init(size: CGSize, hole: CGRect, scale: CGFloat) {
        super.init(frame: CGRect(origin: .zero, size: size))
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        let dim = CAShapeLayer()
        let shade = CGMutablePath()
        shade.addRect(bounds)
        shade.addRect(hole)
        dim.path = shade
        dim.fillRule = .evenOdd
        dim.fillColor = NSColor.black.withAlphaComponent(0.45).cgColor
        let edge = CAShapeLayer()
        edge.path = CGPath(rect: hole.insetBy(dx: -0.5, dy: -0.5), transform: nil)
        edge.fillColor = nil
        edge.strokeColor = NSColor.white.withAlphaComponent(0.6).cgColor
        edge.lineWidth = 1
        for layer in [dim, edge] {
            layer.frame = bounds
            layer.contentsScale = scale
            self.layer?.addSublayer(layer)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

private final class ScrollingControlsPanel: NSPanel {
    /// The recording stage's level (`StagePanel`).
    static let stageLevel = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)

    convenience init(content: ScrollingControlsView) {
        self.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        CaptureChrome.mark(self)
        level = Self.stageLevel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        contentView = content
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class ScrollingControlsView: NSView {
    /// The recording stage's gap between the area and its toolbar (`RecordingStageView.gap`).
    static let gap: CGFloat = 12
    /// The recording stage notice's corner radius.
    private static let cornerRadius: CGFloat = 14
    private static let inset: CGFloat = 8

    let surface: NSView
    private let preview = NSImageView()
    private let heightLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let onFinish: () -> Void
    private let onCancel: () -> Void

    init(previewWidth: CGFloat, onFinish: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.onFinish = onFinish
        self.onCancel = onCancel
        let content = NSStackView()
        surface = Glass.surface(holding: content, cornerRadius: Self.cornerRadius)
        super.init(frame: .zero)

        preview.imageScaling = .scaleProportionallyDown
        preview.imageAlignment = .alignBottom
        preview.wantsLayer = true
        preview.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.2).cgColor
        preview.layer?.cornerRadius = Self.cornerRadius - Self.inset
        preview.layer?.cornerCurve = .continuous
        preview.layer?.masksToBounds = true
        preview.setAccessibilityElement(false)
        NSLayoutConstraint.activate([
            preview.widthAnchor.constraint(equalToConstant: previewWidth),
            preview.heightAnchor.constraint(equalToConstant: ScrollingStage.previewHeight),
        ])

        heightLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        heightLabel.textColor = .labelColor
        heightLabel.setAccessibilityIdentifier(AccessibilityID.scrollingStageHeight)
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        statusLabel.textColor = .systemYellow
        statusLabel.setAccessibilityIdentifier(AccessibilityID.scrollingStageStatus)
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let done = button("Done", symbol: "checkmark", label: "Done (Return)", id: AccessibilityID.scrollingStageDone, action: #selector(finish))
        done.tint = .controlAccentColor
        let cancel = button("Cancel", symbol: nil, label: "Cancel (Esc)", id: AccessibilityID.scrollingStageCancel, action: #selector(cancelCapture))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [heightLabel, statusLabel, spacer, done, cancel])
        row.spacing = 8

        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = Self.inset
        content.edgeInsets = NSEdgeInsets(top: Self.inset, left: Self.inset, bottom: Self.inset, right: Self.inset)
        content.addArrangedSubview(preview)
        content.addArrangedSubview(row)
        row.widthAnchor.constraint(greaterThanOrEqualTo: preview.widthAnchor).isActive = true

        surface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func render(height: String, status: String?) {
        heightLabel.stringValue = height
        statusLabel.stringValue = status ?? ""
        statusLabel.isHidden = status == nil
    }

    func showPreview(_ image: CGImage, scale: CGFloat) {
        preview.image = NSImage(cgImage: image, size: CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
    }

    @objc private func finish() { onFinish() }

    @objc private func cancelCapture() { onCancel() }

    private func button(_ title: String, symbol: String?, label: String, id: String, action: Selector) -> GlassButton {
        let image = symbol.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        }
        let button = image.map { GlassButton(title: title, image: $0, target: self, action: action) }
            ?? GlassButton(title: title, target: self, action: action)
        button.imagePosition = image == nil ? .noImage : .imageLeading
        button.setAccessibilityLabel(label)
        button.setAccessibilityIdentifier(id)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: ceil(button.intrinsicContentSize.width) + 2 * Glass.titlePadding),
            button.heightAnchor.constraint(equalToConstant: Glass.buttonSide),
        ])
        return button
    }
}
