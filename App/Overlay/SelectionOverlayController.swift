import AppKit
import Carbon.HIToolbox
import GlintCapture
import GlintCore

@MainActor
final class SelectionOverlayController: Selecting {
    private var panels: [OverlayPanel] = []
    private var continuation: CheckedContinuation<SelectionResult, Never>?
    private var windowTargets: [WindowTarget] = []
    private var highlightedWindow: WindowTarget?

    func selectArea() async -> SelectionResult {
        let displays = DisplayInfo.onScreens()
        return await present { screen in
            let view = AreaSelectionView(screenFrame: screen.frame, displays: displays)
            view.onSelectionChange = { [weak self] rect in self?.updateAreaSelection(rect) }
            view.onFinish = { [weak self] result in self?.finish(result) }
            return view
        }
    }

    func selectWindow(_ windows: [CapturableWindow]) async -> SelectionResult {
        let mainDisplayHeight = NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height ?? 0
        windowTargets = windows.map {
            WindowTarget(id: $0.id, frame: DisplayGeometry.appKitRect(fromTopLeftGlobal: $0.frame, mainDisplayHeight: mainDisplayHeight))
        }
        highlightedWindow = windowTarget(at: NSEvent.mouseLocation)
        return await present { screen in
            let view = WindowPickerView(screenFrame: screen.frame)
            view.highlight = highlightedWindow?.frame
            view.onPointerMove = { [weak self] point in self?.highlightWindow(at: point) }
            view.onClick = { [weak self] in self?.pickHighlightedWindow() }
            return view
        }
    }

    private func present(_ makeView: (NSScreen) -> OverlayView) async -> SelectionResult {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return .cancelled }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            panels = screens.map { screen in
                let view = makeView(screen)
                view.onCancel = { [weak self] in self?.finish(.cancelled) }
                return OverlayPanel(screen: screen, view: view)
            }
            panels.forEach { $0.orderFrontRegardless() }
            let pointer = NSEvent.mouseLocation
            (panels.first { $0.frame.contains(pointer) } ?? panels[0]).makeKey()
            NSCursor.crosshair.set()
        }
    }

    private func finish(_ result: SelectionResult) {
        guard let continuation else { return }
        self.continuation = nil
        panels.forEach { $0.orderOut(nil) }
        panels = []
        windowTargets = []
        highlightedWindow = nil
        NSCursor.arrow.set()
        continuation.resume(returning: result)
    }

    private func updateAreaSelection(_ rect: CGRect?) {
        for view in panels.compactMap({ $0.contentView as? AreaSelectionView }) {
            view.selection = rect
        }
    }

    private func windowTarget(at point: CGPoint) -> WindowTarget? {
        windowTargets.first { $0.frame.contains(point) }
    }

    private func highlightWindow(at point: CGPoint) {
        let target = windowTarget(at: point)
        guard target != highlightedWindow else { return }
        highlightedWindow = target
        for view in panels.compactMap({ $0.contentView as? WindowPickerView }) {
            view.highlight = target?.frame
        }
    }

    private func pickHighlightedWindow() {
        guard let highlightedWindow else { return }
        finish(.window(highlightedWindow.id))
    }
}

struct WindowTarget: Equatable {
    let id: UInt32
    let frame: CGRect
}

final class OverlayPanel: NSPanel {
    convenience init(screen: NSScreen, view: OverlayView) {
        self.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        animationBehavior = .none
        isReleasedWhenClosed = false
        contentView = view
        setAccessibilityIdentifier(AccessibilityID.selectionOverlay)
        setFrame(screen.frame, display: false)
        makeFirstResponder(view)
    }

    override var canBecomeKey: Bool { true }
}

class OverlayView: NSView {
    let screenFrame: CGRect
    var onCancel: (() -> Void)?

    init(screenFrame: CGRect) {
        self.screenFrame = screenFrame
        super.init(frame: CGRect(origin: .zero, size: screenFrame.size))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    override func keyDown(with event: NSEvent) {
        if Int(event.keyCode) == kVK_Escape {
            onCancel?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onCancel?()
    }

    func local(_ globalRect: CGRect) -> CGRect {
        globalRect.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
    }
}

extension DisplayInfo {
    @MainActor
    static func onScreens() -> [DisplayInfo] {
        NSScreen.screens.compactMap(DisplayInfo.init(screen:))
    }

    @MainActor
    init?(screen: NSScreen) {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        self.init(id: number.uint32Value, frame: screen.frame, scale: screen.backingScaleFactor)
    }
}
