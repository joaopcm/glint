import AppKit
import LunettaUI
import QuartzCore

public enum EditorError: LocalizedError, Equatable {
    case flattenFailed(width: Int, height: Int)

    public var errorDescription: String? {
        switch self {
        case .flattenFailed(let width, let height):
            "Core Graphics could not create a \(width)×\(height) bitmap to draw the annotations into."
        }
    }
}

@MainActor
public final class AnnotationEditor: NSObject, NSWindowDelegate {
    struct ToolItem {
        let tool: EditorCanvas.Tool
        let symbol: String
        let label: String
        let hint: String
    }

    /// Grouped by what the tools do: pick, mark up, hide, frame.
    static let toolGroups: [[ToolItem]] = [
        [
            ToolItem(tool: .select, symbol: "cursorarrow", label: "Select", hint: "Click an annotation to select it, then drag to move it"),
        ],
        [
            ToolItem(tool: .arrow, symbol: "arrow.up.right", label: "Arrow", hint: "Drag to draw an arrow"),
            ToolItem(tool: .rectangle, symbol: "rectangle", label: "Rectangle", hint: "Drag to draw a rectangle"),
            ToolItem(tool: .text, symbol: "textformat", label: "Text", hint: "Click where you want to type"),
            ToolItem(tool: .highlighter, symbol: "highlighter", label: "Highlighter", hint: "Drag across text to highlight it, or anywhere to highlight an area"),
        ],
        [
            ToolItem(tool: .blur, symbol: "drop.halffull", label: "Blur", hint: "Drag over anything you want to blur"),
            ToolItem(tool: .pixelate, symbol: "squareshape.split.3x3", label: "Pixelate", hint: "Drag over anything you want to pixelate"),
        ],
        [
            ToolItem(tool: .crop, symbol: "crop", label: "Crop", hint: "Drag to choose what to keep"),
        ],
    ]
    static let undoSymbol = "arrow.uturn.backward"
    static let redoSymbol = "arrow.uturn.forward"

    private static let tools = toolGroups.flatMap { $0 }
    private static let chromeMargin: CGFloat = 16
    private static let imageMargin: CGFloat = 24
    private static let captionGap: CGFloat = 8
    private static let dockSpacing: CGFloat = 8
    private static let captionFadeOut: TimeInterval = 0.2
    private static let intensityReveal: TimeInterval = 0.2
    // The open dock still has to fit the minimum window: `openIntensitySliderFitsTheSmallestWindow` trips first.
    private static let intensitySliderWidth: CGFloat = 88
    private static let intensityInset: CGFloat = 6
    private static let captionFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
    private static let easeOut = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
    private static let titlebarHeight = NSWindow.frameRect(forContentRect: .zero, styleMask: [.titled]).height
    // Open dock (history 70 + color 52 + tools with slider 377 + save 58 + 3×8 gaps = 581 pt) + 2×16 margins = 613 pt.
    private static let minimumContentSize = CGSize(width: 620, height: 400)
    private static weak var colorPanelOwner: AnnotationEditor?

    public let window: NSWindow
    public let canvas: EditorCanvas
    private let document: AnnotationDocument
    private let onColorChange: (AnnotationColor) -> Void
    private let save: (CGImage) throws -> Void
    private let onClose: () -> Void
    private(set) var toolButtons: [EditorCanvas.Tool: GlassButton] = [:]
    private(set) var colorButton: ColorPickerButton!
    private(set) var palettePanel: ColorPalettePanel?
    private var paletteEventMonitor: Any?
    private var isSyncingColorPanel = false
    private var isDraggingColorPanel = false
    private var undoButton: GlassButton!
    private var redoButton: GlassButton!
    private var toolsBar: NSView!
    private(set) var dock: NSStackView!
    private var dockCenter: NSLayoutConstraint!
    let intensitySlider = IntensitySlider()
    private let intensityHost = NSView()
    private var intensityHostWidth: NSLayoutConstraint!
    private(set) var isIntensityOpen = false
    private let captionLabel = NSTextField(labelWithString: "")
    let captionHost = ClickThroughView()
    private var captionCenter: NSLayoutConstraint?
    private var captions: [ObjectIdentifier: NSAttributedString] = [:]
    private var hoveredControl: NSView?
    private var previousApp: NSRunningApplication?

    public init(
        document: AnnotationDocument,
        title: String,
        pixelsPerPoint: CGFloat,
        initialColor: AnnotationColor = .red,
        onColorChange: @escaping (AnnotationColor) -> Void = { _ in },
        save: @escaping (CGImage) throws -> Void,
        onClose: @escaping () -> Void
    ) {
        self.document = document
        self.onColorChange = onColorChange
        self.save = save
        self.onClose = onClose
        canvas = EditorCanvas(document: document, pixelsPerPoint: pixelsPerPoint)
        canvas.color = initialColor
        window = NSWindow(
            contentRect: CGRect(origin: .zero, size: Self.minimumContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.tabbingMode = .disallowed
        window.backgroundColor = .underPageBackgroundColor
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentMinSize = Self.minimumContentSize
        window.contentView = makeContent()

        canvas.onToolChange = { [weak self] tool in
            self?.closeColorPalette()
            self?.showSelectedTool(tool)
            self?.updateIntensityControl()
            self?.updateCaption()
        }
        canvas.onSelectionChange = { [weak self] in
            self?.updateIntensityControl()
            self?.syncColorUI()
        }
        canvas.onSave = { [weak self] in self?.saveAndClose() }
        document.onChange = { [weak self] in
            self?.canvas.documentChanged()
            self?.updateUndoButtons()
            self?.updateIntensityControl()
            self?.syncColorUI()
            self?.updateCaption(fading: true)
        }
        canvas.tool = .arrow
        Task { await document.loadTextLayout() }
        canvas.documentChanged()
        updateUndoButtons()
        syncColorUI()
        sizeWindow(pixelsPerPoint: pixelsPerPoint)
    }

    public func show(on screen: NSScreen?) {
        if previousApp == nil {
            previousApp = NSWorkspace.shared.frontmostApplication
            if let screen { fit(on: screen) }
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
    }

    // MARK: Layout

    private static var canvasInsets: NSEdgeInsets {
        let dockTop = chromeMargin + Glass.toolbarHeight
        let captionTop = dockTop + captionGap + Glass.capsuleHeight
        return NSEdgeInsets(
            top: titlebarHeight + imageMargin / 2,
            left: imageMargin,
            bottom: captionTop + captionGap,
            right: imageMargin
        )
    }

    private func makeContent() -> NSView {
        canvas.contentInsets = Self.canvasInsets

        var toolItems: [NSView] = []
        for (index, group) in Self.toolGroups.enumerated() {
            if index > 0 { toolItems.append(Glass.divider()) }
            for item in group {
                let button = iconButton(item.symbol, item.label, shortcut: item.tool.shortcut.uppercased(), #selector(chooseTool(_:)))
                button.setButtonType(.pushOnPushOff)
                button.tag = Self.tools.firstIndex { $0.tool == item.tool }!
                toolButtons[item.tool] = button
                toolItems.append(button)
                if item.tool == .pixelate { toolItems.append(makeIntensityHost()) }
            }
        }
        let undoControl = iconButton(Self.undoSymbol, "Undo", shortcut: "⌘Z", #selector(undo))
        let redoControl = iconButton(Self.redoSymbol, "Redo", shortcut: "⇧⌘Z", #selector(redo))
        undoButton = undoControl
        redoButton = redoControl

        let pickerControl = ColorPickerButton(target: self, action: #selector(toggleColorPalette))
        pickerControl.color = canvas.color
        trackHover(of: pickerControl, caption: NSAttributedString(string: "Color", attributes: [
            .font: Self.captionFont,
            .foregroundColor: NSColor.labelColor,
        ]))
        colorButton = pickerControl

        let saveButton = GlassButton(title: "Save", target: self, action: #selector(saveAndClose))
        saveButton.isBordered = false
        saveButton.tint = .white
        saveButton.attributedTitle = NSAttributedString(string: "Save", attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        saveButton.setAccessibilityLabel("Save")
        trackHover(of: saveButton, caption: caption("Save", detail: "⌘S"))

        let tools = Glass.toolbar(toolItems, blending: .withinWindow)
        // The toolbar gaps both sides of anything that isn't a button; the host carries its own inset so it closes to nothing.
        (intensityHost.superview as? NSStackView)?.setCustomSpacing(0, after: toolButtons[.pixelate]!)
        let colors = Glass.toolbar([pickerControl], blending: .withinWindow)
        let history = Glass.toolbar([undoControl, redoControl], blending: .withinWindow)
        let saving = Glass.toolbar([saveButton], tint: .controlAccentColor, blending: .withinWindow)
        toolsBar = tools

        captionLabel.font = Self.captionFont
        captionLabel.textColor = .labelColor
        let capsule = Glass.capsule(holding: captionLabel, blending: .withinWindow)
        capsule.translatesAutoresizingMaskIntoConstraints = false
        captionHost.addSubview(capsule)
        captionHost.alphaValue = 0
        captionHost.isHidden = true

        // One dock in the middle: capture cards sit in a screen corner above every window, so a Save button in the
        // corner of a screen-sized editor ended up under the card (UI test run 45724644945).
        let dock = NSStackView(views: [history, colors, tools, saving])
        dock.spacing = Self.dockSpacing
        self.dock = dock

        let content = NSView()
        dockCenter = dock.centerXAnchor.constraint(equalTo: content.centerXAnchor)
        dockCenter.priority = .defaultHigh // the edges win, so an open intensity slider never pushes the dock off a narrow window
        for view in [canvas, dock, captionHost] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            canvas.topAnchor.constraint(equalTo: content.topAnchor),
            canvas.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            dockCenter,
            dock.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: Self.chromeMargin),
            dock.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -Self.chromeMargin),
            dock.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Self.chromeMargin),
            capsule.leadingAnchor.constraint(equalTo: captionHost.leadingAnchor),
            capsule.trailingAnchor.constraint(equalTo: captionHost.trailingAnchor),
            capsule.topAnchor.constraint(equalTo: captionHost.topAnchor),
            capsule.bottomAnchor.constraint(equalTo: captionHost.bottomAnchor),
            captionHost.heightAnchor.constraint(equalToConstant: Glass.capsuleHeight),
            captionHost.widthAnchor.constraint(equalTo: captionLabel.widthAnchor, constant: 16),
            captionHost.bottomAnchor.constraint(equalTo: tools.topAnchor, constant: -Self.captionGap),
            captionHost.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: Self.chromeMargin),
            captionHost.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -Self.chromeMargin),
        ])
        return content
    }

    private func iconButton(_ symbol: String, _ label: String, shortcut: String, _ action: Selector) -> GlassButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)!
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))!
        let button = GlassButton(image: image, target: self, action: action)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.setAccessibilityLabel(label)
        trackHover(of: button, caption: caption(label, detail: shortcut))
        return button
    }

    private func makeIntensityHost() -> NSView {
        intensitySlider.minValue = 0
        intensitySlider.maxValue = 1
        intensitySlider.isContinuous = true
        intensitySlider.controlSize = .small
        intensitySlider.target = self
        intensitySlider.action = #selector(intensityChanged)
        intensitySlider.alphaValue = 0
        intensitySlider.isHidden = true
        intensitySlider.onHoverChange = { [weak self] hovered in
            guard let self else { return }
            hoverChanged(intensitySlider, hovered)
        }
        intensitySlider.onTrackingEnd = { [weak self] in
            guard let self else { return }
            canvas.setIntensity(intensitySlider.doubleValue, committing: true)
            window.makeFirstResponder(canvas)
        }
        intensitySlider.translatesAutoresizingMaskIntoConstraints = false
        intensityHost.addSubview(intensitySlider)
        intensityHost.clipsToBounds = true
        intensityHostWidth = intensityHost.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            intensityHostWidth,
            intensityHost.heightAnchor.constraint(equalToConstant: Glass.buttonSide),
            intensitySlider.leadingAnchor.constraint(equalTo: intensityHost.leadingAnchor, constant: Self.intensityInset),
            intensitySlider.widthAnchor.constraint(equalToConstant: Self.intensitySliderWidth),
            intensitySlider.centerYAnchor.constraint(equalTo: intensityHost.centerYAnchor),
        ])
        return intensityHost
    }

    private func sizeWindow(pixelsPerPoint: CGFloat) {
        let insets = Self.canvasInsets
        let natural = CGSize(width: CGFloat(document.base.width) / pixelsPerPoint, height: CGFloat(document.base.height) / pixelsPerPoint)
        window.setContentSize(CGSize(
            width: max(natural.width + insets.left + insets.right, Self.minimumContentSize.width),
            height: max(natural.height + insets.top + insets.bottom, Self.minimumContentSize.height)
        ))
    }

    private func fit(on screen: NSScreen) {
        let visible = screen.visibleFrame
        var frame = window.frame
        let fit = min(visible.width / frame.width, visible.height / frame.height, 1)
        frame.size = CGSize(width: frame.width * fit, height: frame.height * fit)
        frame.origin = CGPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2)
        window.setFrame(frame, display: false)
    }

    // MARK: Caption

    /// One glass label above the tools, like the capture card's: the hovered control's name and shortcut or value, and on a
    /// capture with nothing on it yet, how to use the current tool.
    private func caption(_ label: String, detail: String) -> NSAttributedString {
        let text = NSMutableAttributedString(string: label, attributes: [.font: Self.captionFont, .foregroundColor: NSColor.labelColor])
        text.append(NSAttributedString(string: "  \(detail)", attributes: [.font: Self.captionFont, .foregroundColor: NSColor.secondaryLabelColor]))
        return text
    }

    private func trackHover(of button: GlassButton, caption: NSAttributedString) {
        captions[ObjectIdentifier(button)] = caption
        button.onHoverChange = { [weak self] button, hovered in
            self?.hoverChanged(button, hovered)
        }
    }

    private func trackHover(of button: ColorPickerButton, caption: NSAttributedString) {
        captions[ObjectIdentifier(button)] = caption
        button.onHoverChange = { [weak self] button, hovered in
            self?.hoverChanged(button, hovered)
        }
    }

    private func hoverChanged(_ control: NSView, _ hovered: Bool) {
        if hovered {
            hoveredControl = control
        } else if hoveredControl === control {
            hoveredControl = nil
        }
        updateCaption()
    }

    /// The slider's caption reads out its position, so a drag with nothing selected still shows what it changed.
    private func hoverCaption(for control: NSView) -> NSAttributedString? {
        guard control === intensitySlider else { return captions[ObjectIdentifier(control)] }
        guard let target = canvas.intensityTarget else { return nil }
        let percent = Int((intensitySlider.doubleValue * 100).rounded())
        return caption("\(Self.label(of: target.tool)) intensity", detail: "\(percent)%")
    }

    private static func label(of tool: EditorCanvas.Tool) -> String {
        tools.first { $0.tool == tool }?.label ?? ""
    }
    private var showsHint: Bool {
        document.annotations.isEmpty && document.crop == nil
    }

    private func updateCaption(fading: Bool = false) {
        if palettePanel != nil {
            setCaptionAlpha(0, duration: 0)
            return
        }
        let text: NSAttributedString
        let anchor: NSView
        if let hoveredControl, let hovered = hoverCaption(for: hoveredControl) {
            text = hovered
            anchor = hoveredControl
        } else if showsHint, let hint = Self.tools.first(where: { $0.tool == canvas.tool })?.hint {
            text = NSAttributedString(string: hint, attributes: [.font: Self.captionFont, .foregroundColor: NSColor.labelColor])
            anchor = toolsBar
        } else {
            setCaptionAlpha(0, duration: fading ? Self.captionFadeOut : 0)
            return
        }
        captionLabel.attributedStringValue = text
        captionCenter?.isActive = false
        let center = captionHost.centerXAnchor.constraint(equalTo: anchor.centerXAnchor)
        center.priority = .defaultHigh // the edge constraints win, so a caption never spills off the window
        center.isActive = true
        captionCenter = center
        setCaptionAlpha(1, duration: 0)
    }

    /// Hover captions switch instantly, as on the cards; only the hint eases out once the first edit lands.
    private func setCaptionAlpha(_ alpha: CGFloat, duration: TimeInterval) {
        guard duration > 0 else {
            captionHost.alphaValue = alpha
            captionHost.isHidden = alpha == 0
            return
        }
        if alpha > 0 { captionHost.isHidden = false }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = Self.easeOut
            captionHost.animator().alphaValue = alpha
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // Hidden, not just clear, so VoiceOver doesn't read a stale hint; a hover during the fade wins.
                guard let self, self.captionHost.alphaValue == 0 else { return }
                self.captionHost.isHidden = true
            }
        })
    }

    // MARK: Color

    var activeColor: AnnotationColor {
        if let id = canvas.selectedID,
           let selected = document.annotation(id),
           selected.kind.usesColor {
            return selected.color
        }
        return canvas.color
    }

    func applyColor(_ color: AnnotationColor, coalescing: Bool = false) {
        canvas.color = color
        onColorChange(color)
        if let id = canvas.selectedID,
           let selected = document.annotation(id),
           selected.kind.usesColor {
            document.setColor(id, color, coalescing: coalescing)
        }
        syncColorUI()
    }

    private func syncColorUI() {
        let color = activeColor
        colorButton?.color = color
        palettePanel?.selectedColor = color
        if NSColorPanel.sharedColorPanelExists, Self.colorPanelOwner === self {
            let panel = NSColorPanel.shared
            if panel.isVisible, !isDraggingColorPanel {
                isSyncingColorPanel = true
                panel.color = color.nsColor
                isSyncingColorPanel = false
            }
        }
    }

    @objc func toggleColorPalette() {
        if palettePanel != nil {
            closeColorPalette()
        } else {
            openColorPalette()
        }
    }

    func openColorPalette() {
        guard palettePanel == nil else { return }
        window.contentView?.layoutSubtreeIfNeeded()
        let panel = ColorPalettePanel(
            selectedColor: activeColor,
            onSelectColor: { [weak self] color in
                self?.applyColor(color)
                self?.closeColorPalette()
                if let self { self.window.makeFirstResponder(self.canvas.activeResponder) }
            },
            onSelectCustom: { [weak self] in
                self?.openSystemColorPanel()
            }
        )
        let buttonInWindow = colorButton.convert(colorButton.bounds, to: nil)
        let buttonOnScreen = window.convertToScreen(buttonInWindow)
        let size = panel.frame.size
        var origin = CGPoint(
            x: (buttonOnScreen.midX - size.width / 2).rounded(),
            y: (buttonOnScreen.maxY + Self.captionGap).rounded()
        )
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame.insetBy(dx: 8, dy: 8) {
            origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        }
        panel.setFrameOrigin(origin)
        palettePanel = panel
        colorButton.isOpen = true
        updateCaption()

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !reduceMotion { panel.alphaValue = 0 }
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        if !reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.timingFunction = Self.easeOut
                panel.animator().alphaValue = 1
            }
        }

        paletteEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self, let panel = self.palettePanel else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 {
                    self.closeColorPalette()
                    return nil
                }
                return event
            }
            if event.window === panel { return event }
            if event.window === self.window {
                let point = self.colorButton.convert(event.locationInWindow, from: nil)
                if self.colorButton.bounds.contains(point) { return event }
            }
            self.closeColorPalette()
            return event
        }
    }

    func closeColorPalette() {
        if let monitor = paletteEventMonitor {
            NSEvent.removeMonitor(monitor)
            paletteEventMonitor = nil
        }
        guard let panel = palettePanel else { return }
        palettePanel = nil
        colorButton.isOpen = false
        window.removeChildWindow(panel)
        panel.orderOut(nil)
        updateCaption()
    }

    func openSystemColorPanel() {
        closeColorPalette()
        let panel = NSColorPanel.shared
        isSyncingColorPanel = true
        panel.showsAlpha = false
        panel.color = activeColor.nsColor
        isSyncingColorPanel = false
        Self.colorPanelOwner = self
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        panel.orderFront(nil)
    }

    @objc private func colorPanelChanged(_ sender: NSColorPanel) {
        guard !isSyncingColorPanel else { return }
        let eventType = NSApp.currentEvent?.type
        let coalescing = eventType == .leftMouseDragged && isDraggingColorPanel
        isDraggingColorPanel = eventType == .leftMouseDragged || eventType == .leftMouseDown
        applyColor(AnnotationColor(nsColor: sender.color), coalescing: coalescing)
    }

    // MARK: State

    private func showSelectedTool(_ tool: EditorCanvas.Tool) {
        for (candidate, button) in toolButtons {
            button.state = candidate == tool ? .on : .off
        }
    }

    private func updateIntensityControl() {
        guard let target = canvas.intensityTarget else { return setIntensityOpen(false) }
        intensitySlider.setAccessibilityLabel("\(Self.label(of: target.tool)) intensity")
        if !intensitySlider.isTracking { intensitySlider.doubleValue = target.level }
        setIntensityOpen(true)
    }

    private func setIntensityOpen(_ open: Bool) {
        guard open != isIntensityOpen else { return }
        isIntensityOpen = open
        let width = open ? Self.intensityInset + Self.intensitySliderWidth : 0
        // Moving the dock right by half keeps everything left of the slider still, so the Blur or Pixelate button
        // that opened it stays under the pointer.
        let dockOffset = width / 2
        intensitySlider.isHidden = false
        // A tool picked from the keyboard is picked dozens of times a session, so only a click gets the reveal.
        let animates = window.isVisible && NSApp.currentEvent?.type != .keyDown && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard animates else {
            intensityHostWidth.constant = width
            dockCenter.constant = dockOffset
            intensitySlider.alphaValue = open ? 1 : 0
            intensitySlider.isHidden = !open
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.intensityReveal
            context.timingFunction = Self.easeOut
            intensityHostWidth.animator().constant = width
            dockCenter.animator().constant = dockOffset
            intensitySlider.animator().alphaValue = open ? 1 : 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // Hidden once closed, so VoiceOver doesn't find a slider clipped to nothing; reopening mid-close wins.
                guard let self, !self.isIntensityOpen else { return }
                self.intensitySlider.isHidden = true
            }
        })
    }

    @objc private func intensityChanged() {
        canvas.setIntensity(intensitySlider.doubleValue, committing: !intensitySlider.isTracking)
        updateCaption()
    }

    private func updateUndoButtons() {
        undoButton.isEnabled = document.undoManager.canUndo
        redoButton.isEnabled = document.undoManager.canRedo
    }

    @objc private func chooseTool(_ sender: NSButton) {
        canvas.tool = Self.tools[sender.tag].tool
        window.makeFirstResponder(canvas)
    }

    @objc private func undo() {
        closeColorPalette()
        document.undoManager.undo()
    }

    @objc private func redo() {
        closeColorPalette()
        document.undoManager.redo()
    }

    @objc private func saveAndClose() {
        closeColorPalette()
        window.makeFirstResponder(canvas)
        do {
            guard let image = document.flattened() else {
                throw EditorError.flattenFailed(width: document.base.width, height: document.base.height)
            }
            try save(image)
            window.close()
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Lunetta couldn't save the annotated screenshot"
            alert.informativeText = error.localizedDescription
            alert.beginSheetModal(for: window)
        }
    }

    public func windowDidResignKey(_ notification: Notification) {
        closeColorPalette()
    }

    public func windowDidResize(_ notification: Notification) {
        closeColorPalette()
    }

    public func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        document.undoManager
    }

    public func windowWillClose(_ notification: Notification) {
        closeColorPalette()
        if NSColorPanel.sharedColorPanelExists, Self.colorPanelOwner === self {
            Self.colorPanelOwner = nil
            let panel = NSColorPanel.shared
            panel.setTarget(nil)
            panel.setAction(nil)
            panel.close()
        }
        document.onChange = nil
        if NSApp.isActive, let previousApp, previousApp != NSRunningApplication.current {
            NSApp.yieldActivation(to: previousApp)
            previousApp.activate()
        }
        onClose()
    }
}

final class ClickThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
