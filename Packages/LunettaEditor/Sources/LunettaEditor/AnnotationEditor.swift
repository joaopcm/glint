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
            ToolItem(tool: .highlighter, symbol: "highlighter", label: "Highlighter", hint: "Drag across what you want to highlight"),
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
    private static let captionFadeOut: TimeInterval = 0.2
    private static let captionFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
    private static let easeOut = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
    private static let titlebarHeight = NSWindow.frameRect(forContentRect: .zero, styleMask: [.titled]).height
    private static let minimumContentSize = CGSize(width: 560, height: 400)

    public let window: NSWindow
    public let canvas: EditorCanvas
    private let document: AnnotationDocument
    private let save: (CGImage) throws -> Void
    private let onClose: () -> Void
    private var toolButtons: [EditorCanvas.Tool: GlassButton] = [:]
    private var undoButton: GlassButton!
    private var redoButton: GlassButton!
    private var toolsBar: NSView!
    private let captionLabel = NSTextField(labelWithString: "")
    private let captionHost = ClickThroughView()
    private var captionCenter: NSLayoutConstraint?
    private var captions: [ObjectIdentifier: NSAttributedString] = [:]
    private var hoveredButton: GlassButton?
    private var previousApp: NSRunningApplication?

    public init(
        document: AnnotationDocument,
        title: String,
        pixelsPerPoint: CGFloat,
        save: @escaping (CGImage) throws -> Void,
        onClose: @escaping () -> Void
    ) {
        self.document = document
        self.save = save
        self.onClose = onClose
        canvas = EditorCanvas(document: document, pixelsPerPoint: pixelsPerPoint)
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
            self?.showSelectedTool(tool)
            self?.updateCaption()
        }
        canvas.onSave = { [weak self] in self?.saveAndClose() }
        document.onChange = { [weak self] in
            self?.canvas.documentChanged()
            self?.updateUndoButtons()
            self?.updateCaption(fading: true)
        }
        canvas.tool = .arrow
        canvas.documentChanged()
        updateUndoButtons()
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
        NSEdgeInsets(
            top: titlebarHeight + imageMargin / 2,
            left: imageMargin,
            bottom: 2 * chromeMargin + Glass.toolbarHeight,
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
            }
        }
        let undoControl = iconButton(Self.undoSymbol, "Undo", shortcut: "⌘Z", #selector(undo))
        let redoControl = iconButton(Self.redoSymbol, "Redo", shortcut: "⇧⌘Z", #selector(redo))
        undoButton = undoControl
        redoButton = redoControl

        let saveButton = GlassButton(title: "Save", target: self, action: #selector(saveAndClose))
        saveButton.isBordered = false
        saveButton.tint = .white
        saveButton.attributedTitle = NSAttributedString(string: "Save", attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        saveButton.setAccessibilityLabel("Save")
        trackHover(of: saveButton, caption: caption("Save", shortcut: "⌘S"))

        let tools = Glass.toolbar(toolItems, blending: .withinWindow)
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

        let content = NSView()
        for view in [canvas, history, tools, saving, captionHost] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        let centered = tools.centerXAnchor.constraint(equalTo: content.centerXAnchor)
        centered.priority = .defaultHigh // a narrow window slides the tools aside rather than under Undo or Save
        NSLayoutConstraint.activate([
            canvas.topAnchor.constraint(equalTo: content.topAnchor),
            canvas.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            centered,
            tools.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Self.chromeMargin),
            history.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.chromeMargin),
            history.centerYAnchor.constraint(equalTo: tools.centerYAnchor),
            saving.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Self.chromeMargin),
            saving.centerYAnchor.constraint(equalTo: tools.centerYAnchor),
            tools.leadingAnchor.constraint(greaterThanOrEqualTo: history.trailingAnchor, constant: Self.chromeMargin),
            tools.trailingAnchor.constraint(lessThanOrEqualTo: saving.leadingAnchor, constant: -Self.chromeMargin),
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
        trackHover(of: button, caption: caption(label, shortcut: shortcut))
        return button
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

    /// One glass label above the tools, like the capture card's: the hovered button's name and shortcut, and on a
    /// capture with nothing on it yet, how to use the current tool.
    private func caption(_ label: String, shortcut: String) -> NSAttributedString {
        let text = NSMutableAttributedString(string: label, attributes: [.font: Self.captionFont, .foregroundColor: NSColor.labelColor])
        text.append(NSAttributedString(string: "  \(shortcut)", attributes: [.font: Self.captionFont, .foregroundColor: NSColor.secondaryLabelColor]))
        return text
    }

    private func trackHover(of button: GlassButton, caption: NSAttributedString) {
        captions[ObjectIdentifier(button)] = caption
        button.onHoverChange = { [weak self] button, hovered in
            guard let self else { return }
            if hovered {
                hoveredButton = button
            } else if hoveredButton === button {
                hoveredButton = nil
            }
            updateCaption()
        }
    }

    private var showsHint: Bool {
        document.annotations.isEmpty && document.crop == nil
    }

    private func updateCaption(fading: Bool = false) {
        let text: NSAttributedString
        let anchor: NSView
        if let hoveredButton, let hovered = captions[ObjectIdentifier(hoveredButton)] {
            text = hovered
            anchor = hoveredButton
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

    // MARK: State

    private func showSelectedTool(_ tool: EditorCanvas.Tool) {
        for (candidate, button) in toolButtons {
            button.state = candidate == tool ? .on : .off
        }
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
        document.undoManager.undo()
    }

    @objc private func redo() {
        document.undoManager.redo()
    }

    @objc private func saveAndClose() {
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

    public func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        document.undoManager
    }

    public func windowWillClose(_ notification: Notification) {
        document.onChange = nil
        if NSApp.isActive, let previousApp, previousApp != NSRunningApplication.current {
            NSApp.yieldActivation(to: previousApp)
            previousApp.activate()
        }
        onClose()
    }
}

private final class ClickThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
