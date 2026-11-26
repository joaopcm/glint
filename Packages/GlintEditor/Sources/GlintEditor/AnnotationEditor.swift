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
public final class AnnotationEditor: NSObject, NSWindowDelegate, NSToolbarDelegate {
    public let window: NSWindow
    public let canvas: EditorCanvas
    private let document: AnnotationDocument
    private let save: (CGImage) throws -> Void
    private let onClose: () -> Void
    private var toolControl: NSSegmentedControl!
    private var undoItem: NSToolbarItem!
    private var redoItem: NSToolbarItem!
    private var previousApp: NSRunningApplication?

    private static let toolSymbols: [(EditorCanvas.Tool, symbol: String, label: String)] = [
        (.select, "cursorarrow", "Select"),
        (.arrow, "arrow.up.right", "Arrow"),
        (.rectangle, "rectangle", "Rectangle"),
        (.text, "textformat", "Text"),
        (.highlighter, "highlighter", "Highlighter"),
        (.blur, "drop", "Blur"),
        (.pixelate, "squareshape.split.3x3", "Pixelate"),
        (.crop, "crop", "Crop"),
    ]

    private enum Item {
        static let tools = NSToolbarItem.Identifier("tools")
        static let undo = NSToolbarItem.Identifier("undo")
        static let redo = NSToolbarItem.Identifier("redo")
        static let save = NSToolbarItem.Identifier("save")
    }

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
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = title
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.toolbarStyle = .unified
        window.toolbar = makeToolbar()
        window.contentView = makeContent()
        window.contentMinSize = CGSize(width: 480, height: 320 + chromeHeight)

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

    private func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "GlintAnnotationEditor")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        return toolbar
    }

    /// The canvas sits below the toolbar so no toolbar glass ever covers the capture; the backdrop fills the
    /// titlebar strip with the canvas's own color, so on macOS 26 the glass floats over it like Preview's.
    private func makeContent() -> NSView {
        let content = Backdrop()
        canvas.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(canvas)
        NSLayoutConstraint.activate([
            canvas.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor),
            canvas.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        return content
    }

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Item.tools, .space, Item.undo, Item.redo, .flexibleSpace, Item.save]
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    public func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch identifier {
        case Item.tools:
            let control = NSSegmentedControl(
                images: Self.toolSymbols.map { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: $0.label)! },
                trackingMode: .selectOne,
                target: self,
                action: #selector(chooseTool(_:))
            )
            for (index, tool) in Self.toolSymbols.enumerated() { control.setToolTip(tool.label, forSegment: index) }
            toolControl = control
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = control
            item.label = "Tools"
            return item
        case Item.undo:
            undoItem = iconItem(identifier, "arrow.uturn.backward", "Undo", #selector(undo))
            return undoItem
        case Item.redo:
            redoItem = iconItem(identifier, "arrow.uturn.forward", "Redo", #selector(redo))
            return redoItem
        case Item.save:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.title = "Save"
            item.paletteLabel = "Save"
            item.toolTip = "Save over the capture (⌘S)"
            item.isBordered = true
            item.target = self
            item.action = #selector(saveAndClose)
            if #available(macOS 26, *) { item.style = .prominent }
            return item
        default:
            return nil
        }
    }

    private func iconItem(_ identifier: NSToolbarItem.Identifier, _ symbol: String, _ label: String, _ action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.label = label
        item.toolTip = label
        item.isBordered = true
        item.autovalidates = false
        item.target = self
        item.action = action
        return item
    }

    private var chromeHeight: CGFloat {
        window.frame.height - window.contentLayoutRect.height
    }

    private func sizeWindow(pixelsPerPoint: CGFloat) {
        let natural = CGSize(width: CGFloat(document.base.width) / pixelsPerPoint, height: CGFloat(document.base.height) / pixelsPerPoint)
        window.setContentSize(CGSize(width: max(natural.width, 480), height: max(natural.height, 320) + chromeHeight))
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
        toolControl.selectedSegment = Self.toolSymbols.firstIndex { $0.0 == tool } ?? -1
    }

    private func updateUndoButtons() {
        undoItem.isEnabled = document.undoManager.canUndo
        redoItem.isEnabled = document.undoManager.canRedo
    }

    @objc private func chooseTool(_ sender: NSSegmentedControl) {
        canvas.tool = Self.toolSymbols[sender.selectedSegment].0
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

private final class Backdrop: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill()
        dirtyRect.fill()
    }
}
