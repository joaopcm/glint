import AppKit

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
    public let window: NSWindow
    public let canvas: EditorCanvas
    private let document: AnnotationDocument
    private let save: (CGImage) throws -> Void
    private let onClose: () -> Void
    private var toolButtons: [EditorCanvas.Tool: NSButton] = [:]
    private var undoButton: NSButton!
    private var redoButton: NSButton!
    private var previousApp: NSRunningApplication?

    private static let toolSymbols: [(EditorCanvas.Tool, symbol: String, label: String)] = [
        (.select, "cursorarrow", "Select"),
        (.arrow, "arrow.up.right", "Arrow"),
        (.rectangle, "rectangle", "Rectangle"),
        (.text, "textformat", "Text"),
        (.highlighter, "highlighter", "Highlighter"),
    ]

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
            contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = title
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentMinSize = CGSize(width: 480, height: 320)
        window.contentView = makeContent()

        canvas.onToolChange = { [weak self] tool in self?.showSelectedTool(tool) }
        canvas.onSave = { [weak self] in self?.saveAndClose() }
        document.onChange = { [weak self] in
            self?.canvas.documentChanged()
            self?.updateUndoButtons()
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

    private func makeContent() -> NSView {
        var tools: [NSView] = []
        for (tool, symbol, label) in Self.toolSymbols {
            let button = iconButton(symbol, label, #selector(chooseTool(_:)))
            button.setButtonType(.pushOnPushOff)
            button.tag = Self.toolSymbols.firstIndex { $0.0 == tool }!
            toolButtons[tool] = button
            tools.append(button)
        }
        undoButton = iconButton("arrow.uturn.backward", "Undo", #selector(undo))
        redoButton = iconButton("arrow.uturn.forward", "Redo", #selector(redo))
        let saveButton = NSButton(title: "Save", target: self, action: #selector(saveAndClose))
        saveButton.bezelStyle = .push
        saveButton.toolTip = "Save over the capture (⌘S)"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bar = NSStackView(views: tools + [separator(), undoButton, redoButton, spacer, saveButton])
        bar.spacing = 4
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)

        let content = NSView()
        for view in [bar, canvas] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: bar.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        return content
    }

    private func iconButton(_ symbol: String, _ label: String, _ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)!
        let button = NSButton(image: image, target: self, action: action)
        button.bezelStyle = .toolbar
        button.toolTip = label
        button.setAccessibilityLabel(label)
        return button
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return line
    }

    private func sizeWindow(pixelsPerPoint: CGFloat) {
        let natural = CGSize(width: CGFloat(document.base.width) / pixelsPerPoint, height: CGFloat(document.base.height) / pixelsPerPoint)
        let barHeight = window.contentView?.fittingSize.height ?? 0
        window.setContentSize(CGSize(width: max(natural.width, 480), height: max(natural.height + barHeight, 320)))
    }

    private func fit(on screen: NSScreen) {
        let visible = screen.visibleFrame
        var frame = window.frame
        let fit = min(visible.width / frame.width, visible.height / frame.height, 1)
        frame.size = CGSize(width: frame.width * fit, height: frame.height * fit)
        frame.origin = CGPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2)
        window.setFrame(frame, display: false)
    }

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
        canvas.tool = Self.toolSymbols[sender.tag].0
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
            alert.messageText = "Glint couldn't save the annotated screenshot"
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
