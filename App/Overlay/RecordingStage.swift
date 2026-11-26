import AppKit
import Carbon.HIToolbox
import LunettaCore
import LunettaUI

/// What the stage shows besides the settings themselves: the inputs connected now and what would keep the choices
/// from recording. Permissions change in System Settings without telling Lunetta, so both are re-read on `refresh`.
@MainActor
final class RecordingStageModel {
    let settings: LunettaSettings
    private(set) var problems: [RecordingProblem] = []
    private(set) var connectedInputs: [AudioInput] = []
    var onChange: (@MainActor () -> Void)?
    private let checkProblems: @MainActor () -> [RecordingProblem]
    private let listInputs: @MainActor () -> [AudioInput]
    private let applyFix: @MainActor (RecordingFix) async -> Void

    init(
        settings: LunettaSettings,
        problems: @escaping @MainActor () -> [RecordingProblem],
        inputs: @escaping @MainActor () -> [AudioInput],
        fix: @escaping @MainActor (RecordingFix) async -> Void
    ) {
        self.settings = settings
        checkProblems = problems
        listInputs = inputs
        applyFix = fix
    }

    /// A saved input that isn't connected stays listed, so the menu still shows what the notice complains about.
    var pickableInputs: [AudioInput] {
        guard let saved = settings.recordingInput, !connectedInputs.contains(saved) else { return connectedInputs }
        return connectedInputs + [saved]
    }

    func isConnected(_ input: AudioInput) -> Bool {
        connectedInputs.contains { $0.id == input.id }
    }

    func refresh() {
        connectedInputs = listInputs()
        problems = checkProblems()
        onChange?()
    }

    func fix(_ fix: RecordingFix) {
        Task {
            await applyFix(fix)
            refresh()
        }
    }
}

/// Between picking an area and recording it: the area stays up with grips to move and resize it, and a toolbar under
/// it holds what to record. Record hands the area to the countdown; Esc or the close button drops it.
@MainActor
final class RecordingStage: RecordingStaging {
    /// The countdown's dim fades in over 0.3 s (`RecordingHUD.showDim`); fading the stage out over the same time
    /// keeps the area dimmed the whole way from the stage into the recording.
    private static let handOffDuration: TimeInterval = 0.3

    private let model: RecordingStageModel
    private var panel: StagePanel?
    private var view: RecordingStageView?
    private var decision: CheckedContinuation<CGRect?, Never>?

    init(model: RecordingStageModel) {
        self.model = model
        model.onChange = { [weak self] in self?.view?.render() }
    }

    func stage(_ region: CGRect, on display: DisplayInfo) async -> CGRect? {
        guard let screen = NSScreen.screens.first(where: { $0.frame == display.frame }) else { return region }
        return await withCheckedContinuation { continuation in
            decision = continuation
            let view = RecordingStageView(screen: screen, display: display, area: region, model: model)
            view.onDecide = { [weak self] area in self?.decide(area) }
            let panel = StagePanel(screen: screen, view: view)
            self.view = view
            self.panel = panel
            model.refresh()
            panel.orderFrontRegardless()
            panel.makeKey()
            view.enter(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        }
    }

    /// Inputs plugging in or out while the stage is up.
    func refresh() {
        guard view != nil else { return }
        model.refresh()
    }

    private func decide(_ area: CGRect?) {
        guard let decision, let panel else { return }
        self.decision = nil
        self.panel = nil
        view = nil
        NSCursor.arrow.set()
        if area == nil {
            panel.orderOut(nil)
        } else {
            panel.ignoresMouseEvents = true
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.handOffDuration
                context.timingFunction = ThumbnailPresenter.easeOut
                panel.animator().alphaValue = 0
            } completionHandler: {
                panel.orderOut(nil)
            }
        }
        decision.resume(returning: area)
    }
}

private final class StagePanel: NSPanel {
    convenience init(screen: NSScreen, view: RecordingStageView) {
        self.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        CaptureChrome.mark(self)
        // Under the pop-up menu level, so the input menu opens on top of the stage instead of behind it.
        level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        // A transparent window lets clicks through its clear pixels unless this is set explicitly. The area is the
        // one clear part of the stage, so without it a drag meant to move the area went to the app underneath.
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        animationBehavior = .none
        isReleasedWhenClosed = false
        contentView = view
        setFrame(screen.frame, display: false)
        makeFirstResponder(view)
    }

    override var canBecomeKey: Bool { true }
}

private final class RecordingStageView: NSView {
    private static let gap: CGFloat = 12
    /// About 50 characters a line at the 11 pt notice font, inside the 45 to 75 a line that reads comfortably
    /// (Bringhurst, The Elements of Typographic Style, 2.1.2).
    private static let noticeTextWidth: CGFloat = 300
    private static let handleDiameter: CGFloat = 9
    private static let sizeFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)

    var onDecide: ((CGRect?) -> Void)?

    private let screenFrame: CGRect
    private let visibleFrame: CGRect
    private let display: DisplayInfo
    private let model: RecordingStageModel
    private var area: CGRect {
        didSet { if area != oldValue { layoutArea() } }
    }
    private var drag: StageDrag?
    private var areaBeforeDrag: CGRect?

    private let dim = CAShapeLayer()
    private let edge = CAShapeLayer()
    private let handles = StageHandle.allCases.map { _ in CAShapeLayer() }
    private let sizeBadge = CALayer()
    private let sizeLabel = CATextLayer()

    private lazy var systemAudioButton = toggle("speaker.wave.2.fill", "System Audio", AccessibilityID.recordingStageSystemAudio, #selector(toggleSystemAudio(_:)))
    private lazy var microphoneButton = toggle("mic.fill", "Microphone", AccessibilityID.recordingStageMicrophone, #selector(toggleMicrophone(_:)))
    /// The chosen input's name, then the up-and-down chevron macOS puts on every pop-up button.
    private lazy var inputButton: GlassButton = {
        // At the title's own size and the symbol's small scale, the chevron centers on the text like a menu's does;
        // a 9 pt symbol beside 13 pt text sat off its middle.
        let chevron = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: NSFont.systemFontSize, weight: .semibold, scale: .small))!
        let button = GlassButton(title: "System Default", image: chevron, target: self, action: #selector(chooseInput(_:)))
        button.imagePosition = .imageTrailing
        button.setAccessibilityIdentifier(AccessibilityID.recordingStageInput)
        return button
    }()
    private var inputWidth: NSLayoutConstraint?
    private lazy var keysButton = toggle("keyboard", "Show Pressed Keys", AccessibilityID.recordingStagePressedKeys, #selector(toggleKeys(_:)))
    private lazy var clicksButton = toggle("cursorarrow.click.2", "Highlight Clicks", AccessibilityID.recordingStageClicks, #selector(toggleClicks(_:)))
    private lazy var recordButton: GlassButton = {
        let button = GlassButton(title: "Record", image: Self.symbol("record.circle.fill", "Record"), target: self, action: #selector(record))
        button.imagePosition = .imageLeading
        button.tint = .systemRed
        button.setAccessibilityLabel("Record (Return)")
        button.setAccessibilityIdentifier(AccessibilityID.recordingStageRecord)
        return button
    }()
    private lazy var cancelButton = button("xmark", "Cancel (Esc)", AccessibilityID.recordingStageCancel, #selector(cancel))
    private lazy var toolbar = Glass.toolbar([
        systemAudioButton, microphoneButton, inputButton, Glass.divider(), keysButton, clicksButton, Glass.divider(), recordButton, cancelButton,
    ])
    private var notice: NSView?
    private var chrome: StageChrome?
    private let actionLabel = NSTextField(labelWithString: "")
    private lazy var actionLabelCapsule = Glass.capsule(holding: actionLabel)
    private var hoveredButton: GlassButton?

    init(screen: NSScreen, display: DisplayInfo, area: CGRect, model: RecordingStageModel) {
        screenFrame = screen.frame
        visibleFrame = screen.visibleFrame
        self.display = display
        self.model = model
        self.area = area
        super.init(frame: CGRect(origin: .zero, size: screen.frame.size))
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        setAccessibilityElement(true)
        setAccessibilityRole(.layoutArea)
        setAccessibilityLabel("Area to record")
        setAccessibilityIdentifier(AccessibilityID.recordingStage)

        dim.fillRule = .evenOdd
        dim.fillColor = NSColor.black.withAlphaComponent(0.45).cgColor
        edge.fillColor = nil
        edge.strokeColor = NSColor.white.withAlphaComponent(0.6).cgColor
        edge.lineWidth = 1
        dim.frame = bounds
        edge.frame = bounds
        layer?.addSublayer(dim)
        layer?.addSublayer(edge)
        for handle in handles {
            handle.fillColor = NSColor.white.cgColor
            handle.strokeColor = NSColor.black.withAlphaComponent(0.25).cgColor
            handle.lineWidth = 1
            handle.shadowColor = NSColor.black.cgColor
            handle.shadowOpacity = 0.3
            handle.shadowRadius = 2
            handle.shadowOffset = CGSize(width: 0, height: -1)
            layer?.addSublayer(handle)
        }
        sizeBadge.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        sizeBadge.cornerRadius = 4
        sizeBadge.cornerCurve = .continuous
        sizeLabel.font = Self.sizeFont
        sizeLabel.fontSize = Self.sizeFont.pointSize
        sizeLabel.foregroundColor = NSColor.white.cgColor
        sizeLabel.contentsScale = display.scale
        sizeBadge.addSublayer(sizeLabel)
        layer?.addSublayer(sizeBadge)
        for layer in [dim, edge] + handles { layer.contentsScale = display.scale }

        toolbar.wantsLayer = true
        addSubview(toolbar)
        // `Glass.toolbar` fixes a titled button's width to its title at creation; the input's name changes.
        inputButton.constraints.filter { $0.firstAttribute == .width && $0.secondItem == nil && type(of: $0) == NSLayoutConstraint.self }
            .forEach { $0.isActive = false }
        let inputWidth = inputButton.widthAnchor.constraint(equalToConstant: 0)
        inputWidth.isActive = true
        self.inputWidth = inputWidth
        actionLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        actionLabel.textColor = .labelColor
        actionLabel.setAccessibilityIdentifier(AccessibilityID.recordingStageActionLabel)
        actionLabelCapsule.isHidden = true
        addSubview(actionLabelCapsule)
        for button in [systemAudioButton, microphoneButton, inputButton, keysButton, clicksButton, recordButton, cancelButton] {
            button.onHoverChange = { [weak self] button, hovered in self?.hover(button, hovered) }
        }
        layoutArea()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }

    override func accessibilityChildren() -> [Any]? {
        let label: [NSView] = actionLabelCapsule.isHidden ? [] : [actionLabelCapsule]
        return NSAccessibility.unignoredChildren(from: [toolbar] + (notice.map { [$0] } ?? []) + label)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The toolbar comes up from just below where it rests, the way the recording controls do.
    func enter(reduceMotion: Bool) {
        guard let layer = toolbar.layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let rise = CABasicAnimation(keyPath: "transform.translation.y")
        rise.fromValue = -8
        rise.toValue = 0
        let group = CAAnimationGroup()
        group.animations = reduceMotion ? [fade] : [fade, rise]
        group.duration = ThumbnailPresenter.enterDuration
        group.timingFunction = ThumbnailPresenter.easeOut
        layer.add(group, forKey: "enter")
    }

    // MARK: Choices

    func render() {
        let settings = model.settings
        systemAudioButton.state = settings.recordSystemAudio ? .on : .off
        microphoneButton.state = settings.recordMicrophone ? .on : .off
        keysButton.state = settings.showPressedKeys ? .on : .off
        clicksButton.state = settings.showMouseClicks ? .on : .off
        inputButton.isEnabled = settings.recordMicrophone
        let inputName = settings.recordingInput?.name ?? "System Default"
        inputButton.title = Self.inputTitle(inputName, font: inputButton.font)
        inputButton.setAccessibilityLabel("Input: \(inputName)")
        inputWidth?.constant = ceil(inputButton.intrinsicContentSize.width) + 2 * Glass.titlePadding
        updateRecordButton()
        notice?.removeFromSuperview()
        notice = model.problems.isEmpty ? nil : makeNotice(model.problems)
        if let notice { addSubview(notice) }
        layoutChrome()
    }

    private var recordablePixelSize: (width: Int, height: Int)? {
        guard let source = DisplayGeometry.sourceRect(for: area, on: display),
              let region = RecordingGeometry.evenPixelRegion(of: source, scale: display.scale)
        else { return nil }
        return (region.width, region.height)
    }

    private func updateRecordButton() {
        recordButton.isEnabled = model.problems.isEmpty && recordablePixelSize != nil
    }

    @objc private func toggleSystemAudio(_ sender: NSButton) {
        model.settings.recordSystemAudio = sender.state == .on
        model.refresh()
    }

    @objc private func toggleMicrophone(_ sender: NSButton) {
        model.settings.recordMicrophone = sender.state == .on
        model.refresh()
    }

    @objc private func toggleKeys(_ sender: NSButton) {
        model.settings.showPressedKeys = sender.state == .on
        model.refresh()
    }

    @objc private func toggleClicks(_ sender: NSButton) {
        model.settings.showMouseClicks = sender.state == .on
        model.refresh()
    }

    @objc private func chooseInput(_ sender: NSButton) {
        let menu = NSMenu()
        let chosen = model.settings.recordingInput?.id
        let systemDefault = NSMenuItem(title: "System Default", action: #selector(pickInput(_:)), keyEquivalent: "")
        systemDefault.target = self
        systemDefault.state = chosen == nil ? .on : .off
        menu.addItem(systemDefault)
        if !model.pickableInputs.isEmpty { menu.addItem(.separator()) }
        for input in model.pickableInputs {
            let title = model.isConnected(input) ? input.name : "\(input.name) (not connected)"
            let item = NSMenuItem(title: title, action: #selector(pickInput(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = input.id
            item.state = input.id == chosen ? .on : .off
            menu.addItem(item)
        }
        inputButton.isShowingMenu = true
        _ = menu.popUp(positioning: nil, at: CGPoint(x: 0, y: sender.bounds.maxY + 6), in: sender)
        inputButton.isShowingMenu = false
    }

    @objc private func pickInput(_ item: NSMenuItem) {
        let id = item.representedObject as? String
        model.settings.recordingInput = model.pickableInputs.first { $0.id == id }
        model.refresh()
    }

    @objc private func applyFix(_ sender: NSButton) {
        guard model.problems.indices.contains(sender.tag), let fix = model.problems[sender.tag].fix else { return }
        model.fix(fix)
    }

    @objc private func record() {
        guard recordButton.isEnabled else { return }
        onDecide?(area)
    }

    @objc private func cancel() {
        onDecide?(nil)
    }

    private func makeNotice(_ problems: [RecordingProblem]) -> NSView {
        let rows = problems.enumerated().map { index, problem -> NSView in
            let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)!)
            icon.contentTintColor = .systemYellow
            icon.setContentHuggingPriority(.required, for: .horizontal)
            let message = NSTextField(wrappingLabelWithString: problem.localizedDescription)
            message.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            message.textColor = .labelColor
            message.preferredMaxLayoutWidth = Self.noticeTextWidth
            // Without a set width the glass sized itself to the label's one-line fit and cut the message off.
            message.widthAnchor.constraint(equalToConstant: Self.noticeTextWidth).isActive = true
            var column: [NSView] = [message]
            if let fix = problem.fix {
                let button = NSButton(title: fix.rawValue, target: self, action: #selector(applyFix(_:)))
                button.controlSize = .small
                button.tag = index
                column.append(button)
            }
            let text = NSStackView(views: column)
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 6
            let row = NSStackView(views: [icon, text])
            row.alignment = .top
            row.spacing = 8
            return row
        }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        let notice = Glass.surface(holding: stack, cornerRadius: 14)
        notice.setAccessibilityElement(true)
        notice.setAccessibilityRole(.group)
        notice.setAccessibilityIdentifier(AccessibilityID.recordingStageNotice)
        return notice
    }

    /// 140 pt of name is about 22 characters at the toolbar's 13 pt, enough for "MacBook Pro Microphone", the
    /// built-in input on Apple silicon MacBook Pros. A longer name ends in an ellipsis; the hover label has it whole.
    private static let inputNameMaxWidth: CGFloat = 140

    /// Shortened here, not by the cell: a cell truncates until the title fills the whole button, which pushed the name
    /// and chevron against both edges.
    private static func inputTitle(_ name: String, font: NSFont?) -> String {
        let font = font ?? .systemFont(ofSize: NSFont.systemFontSize)
        return TextTruncation.tail(name, fitting: Double(inputNameMaxWidth)) { Double(($0 as NSString).size(withAttributes: [.font: font]).width) }
    }

    // MARK: Area

    private func local(_ global: CGRect) -> CGRect {
        global.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
    }

    private func layoutArea() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let hole = local(area)
        let shade = CGMutablePath()
        shade.addRect(bounds)
        shade.addRect(hole)
        dim.path = shade
        edge.path = CGPath(rect: hole.insetBy(dx: -0.5, dy: -0.5), transform: nil)
        for (handle, layer) in zip(StageHandle.allCases, handles) {
            let center = StageGeometry.point(of: handle, on: hole)
            let side = Self.handleDiameter
            layer.path = CGPath(ellipseIn: CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side), transform: nil)
        }
        layoutSizeBadge(hole: hole)
        CATransaction.commit()
        updateRecordButton()
        layoutChrome()
    }

    /// The size the file will be: the recording trims odd pixel rows and columns (`RecordingGeometry.evenPixelRegion`).
    private func layoutSizeBadge(hole: CGRect) {
        let text = recordablePixelSize.map { "\($0.width) × \($0.height)" } ?? "Too small to record"
        sizeLabel.string = text
        setAccessibilityValue(text)
        let measured = (text as NSString).size(withAttributes: [.font: Self.sizeFont])
        let padding = CGSize(width: 6, height: 3)
        let size = CGSize(width: ceil(measured.width) + padding.width * 2, height: ceil(measured.height) + padding.height * 2)
        let above = hole.maxY + 6
        let y = above + size.height <= bounds.maxY ? above : hole.maxY - 6 - size.height
        sizeBadge.frame = CGRect(x: max(hole.minX, 0), y: y, width: size.width, height: size.height)
        sizeLabel.frame = CGRect(x: padding.width, y: padding.height, width: ceil(measured.width), height: ceil(measured.height))
    }

    private func layoutChrome() {
        let chrome = StageGeometry.chrome(
            toolbar: Glass.fittingSize(of: toolbar),
            labelHeight: Glass.capsuleHeight,
            notice: notice.map { Glass.fittingSize(of: $0) },
            region: area,
            visible: visibleFrame,
            gap: Self.gap
        )
        self.chrome = chrome
        toolbar.frame = local(chrome.toolbar)
        if let notice, let frame = chrome.notice { notice.frame = local(frame) }
        layoutLabel()
    }

    // MARK: Hover labels

    private func hover(_ button: GlassButton, _ hovered: Bool) {
        if hovered {
            hoveredButton = button
        } else if hoveredButton === button {
            hoveredButton = nil
        }
        layoutLabel()
    }

    private func layoutLabel() {
        guard let button = hoveredButton, let chrome, let text = button.accessibilityLabel(), !text.isEmpty else {
            actionLabelCapsule.isHidden = true
            return
        }
        actionLabel.stringValue = text
        let textWidth = ceil((text as NSString).size(withAttributes: [.font: actionLabel.font!]).width)
        let size = CGSize(width: textWidth + 16, height: Glass.capsuleHeight)
        let buttonMidX = button.convert(button.bounds, to: self).midX + screenFrame.minX
        actionLabelCapsule.frame = local(StageGeometry.labelFrame(size: size, over: buttonMidX, in: chrome.labelLane))
        actionLabelCapsule.isHidden = false
    }

    // MARK: Pointer and keys

    private func isOnChrome(_ localPoint: CGPoint) -> Bool {
        toolbar.frame.contains(localPoint) || notice?.frame.contains(localPoint) == true
    }

    override func mouseDown(with event: NSEvent) {
        let point = event.screenLocation
        guard !isOnChrome(convert(event.locationInWindow, from: nil)) else { return }
        areaBeforeDrag = area
        drag = StageGeometry.drag(startingAt: point, on: area)
        updateCursor(at: point)
    }

    override func mouseDragged(with event: NSEvent) {
        follow(pointer: event.screenLocation, keepingAspectRatio: event.modifierFlags.contains(.shift))
    }

    /// Pressing or letting go of ⇧ mid-drag reshapes the area right away, without waiting for the pointer to move.
    override func flagsChanged(with event: NSEvent) {
        follow(pointer: NSEvent.mouseLocation, keepingAspectRatio: event.modifierFlags.contains(.shift))
        super.flagsChanged(with: event)
    }

    private func follow(pointer: CGPoint, keepingAspectRatio: Bool) {
        guard let drag else { return }
        area = StageGeometry.rect(for: drag, pointer: pointer, bounds: screenFrame, keepingAspectRatio: keepingAspectRatio)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            drag = nil
            areaBeforeDrag = nil
            updateCursor(at: event.screenLocation)
        }
        // A click outside the area draws nothing; keep the area it would have replaced.
        if case .draw = drag, area.width < 1 || area.height < 1, let areaBeforeDrag {
            area = areaBeforeDrag
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(at: event.screenLocation)
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(at: event.screenLocation)
    }

    private func updateCursor(at point: CGPoint) {
        if isOnChrome(CGPoint(x: point.x - screenFrame.minX, y: point.y - screenFrame.minY)) {
            NSCursor.arrow.set()
        } else if case .move = drag {
            NSCursor.closedHand.set()
        } else if let handle = StageGeometry.handle(at: point, on: area) {
            NSCursor.frameResize(position: Self.cursorPosition(handle), directions: .all).set()
        } else if area.contains(point) {
            NSCursor.openHand.set()
        } else {
            NSCursor.crosshair.set()
        }
    }

    private static func cursorPosition(_ handle: StageHandle) -> NSCursor.FrameResizePosition {
        switch handle {
        case .topLeft: .topLeft
        case .top: .top
        case .topRight: .topRight
        case .right: .right
        case .bottomRight: .bottomRight
        case .bottom: .bottom
        case .bottomLeft: .bottomLeft
        case .left: .left
        }
    }

    /// Arrows nudge the area a point at a time, ⇧ ten at a time, the step Keynote and Figma use.
    override func keyDown(with event: NSEvent) {
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        let nudge: CGPoint? = switch Int(event.keyCode) {
        case kVK_LeftArrow: CGPoint(x: -step, y: 0)
        case kVK_RightArrow: CGPoint(x: step, y: 0)
        case kVK_UpArrow: CGPoint(x: 0, y: step)
        case kVK_DownArrow: CGPoint(x: 0, y: -step)
        default: nil
        }
        if let nudge {
            area = StageGeometry.nudge(area, by: nudge, in: screenFrame)
            return
        }
        switch Int(event.keyCode) {
        case kVK_Escape: cancel()
        case kVK_Return, kVK_ANSI_KeypadEnter: record()
        default: super.keyDown(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        cancel()
    }

    // MARK: Buttons

    private static func symbol(_ name: String, _ label: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: label)!
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))!
    }

    private func button(_ symbol: String, _ label: String, _ id: String, _ action: Selector) -> GlassButton {
        let button = GlassButton(image: Self.symbol(symbol, label), target: self, action: action)
        button.imagePosition = .imageOnly
        button.setAccessibilityLabel(label)
        button.setAccessibilityIdentifier(id)
        return button
    }

    private func toggle(_ symbol: String, _ label: String, _ id: String, _ action: Selector) -> GlassButton {
        let button = button(symbol, label, id, action)
        button.setButtonType(.pushOnPushOff)
        return button
    }
}
