import AppKit
import Carbon.HIToolbox
import GlintCapture
import GlintCore

@MainActor
final class SelectionOverlayController: Selecting {
    private var panels: [OverlayPanel] = []
    private var continuation: CheckedContinuation<SelectionResult, any Error>?
    private var windowLoading: Task<Void, Never>?
    private var windowTargets: [WindowTarget]?
    private var pendingClick: CGPoint?
    private var highlightedWindow: WindowTarget?

    func selectArea(frozen: [FrozenDisplay]) async throws -> SelectionResult {
        let displays = DisplayInfo.onScreens()
        return try await present { screen in
            let backdrop = frozen.first { $0.display.frame == screen.frame }?.image
            let view = AreaSelectionView(screenFrame: screen.frame, displays: displays, backdrop: backdrop)
            view.onSelectionChange = { [weak self] rect in self?.updateAreaSelection(rect) }
            view.onFinish = { [weak self] result in self?.finish(result) }
            return view
        }
    }

    func selectWindow(_ windows: Task<[CapturableWindow], any Error>) async throws -> SelectionResult {
        try await present { screen in
            let view = WindowPickerView(screenFrame: screen.frame)
            view.onPointerMove = { [weak self] point in self?.highlightWindow(at: point) }
            view.onClick = { [weak self] point in self?.pickWindow(at: point) }
            return view
        } afterShowing: {
            windowLoading = Task { [weak self] in
                let result = await windows.result
                guard !Task.isCancelled else { return }
                self?.windowsLoaded(result)
            }
        }
    }

    private func present(_ makeView: (NSScreen) -> OverlayView, afterShowing: () -> Void = {}) async throws -> SelectionResult {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return .cancelled }
        return try await withCheckedThrowingContinuation { continuation in
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
            afterShowing()
        }
    }

    private func finish(_ result: SelectionResult) {
        close()?.resume(returning: result)
    }

    private func fail(_ error: any Error) {
        close()?.resume(throwing: error)
    }

    private func close() -> CheckedContinuation<SelectionResult, any Error>? {
        guard let continuation else { return nil }
        self.continuation = nil
        windowLoading?.cancel()
        windowLoading = nil
        panels.forEach { $0.orderOut(nil) }
        panels = []
        windowTargets = nil
        pendingClick = nil
        highlightedWindow = nil
        NSCursor.arrow.set()
        return continuation
    }

    private func updateAreaSelection(_ rect: CGRect?) {
        for view in panels.compactMap({ $0.contentView as? AreaSelectionView }) {
            view.selection = rect
        }
    }

    private func windowsLoaded(_ result: Result<[CapturableWindow], any Error>) {
        let windows: [CapturableWindow]
        do {
            windows = try result.get()
        } catch {
            fail(error)
            return
        }
        let mainDisplayHeight = NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height ?? 0
        windowTargets = windows.map {
            WindowTarget(id: $0.id, frame: DisplayGeometry.appKitRect(fromTopLeftGlobal: $0.frame, mainDisplayHeight: mainDisplayHeight))
        }
        if let pendingClick, let target = windowTarget(at: pendingClick) {
            finish(.window(target.id))
            return
        }
        pendingClick = nil
        highlightWindow(at: NSEvent.mouseLocation)
    }

    private func windowTarget(at point: CGPoint) -> WindowTarget? {
        windowTargets?.first { $0.frame.contains(point) }
    }

    private func highlightWindow(at point: CGPoint) {
        let target = windowTarget(at: point)
        guard target != highlightedWindow else { return }
        highlightedWindow = target
        for view in panels.compactMap({ $0.contentView as? WindowPickerView }) {
            view.highlight = target?.frame
        }
    }

    private func pickWindow(at point: CGPoint) {
        guard windowTargets != nil else {
            pendingClick = point
            return
        }
        guard let target = windowTarget(at: point) else { return }
        finish(.window(target.id))
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
        // A borderless panel with no accessible content is invisible to VoiceOver and XCUITest (run 45282671146).
        setAccessibilityElement(true)
        setAccessibilityRole(.layoutArea)
        setAccessibilityLabel("Screen capture selection")
        setAccessibilityIdentifier(AccessibilityID.selectionOverlay)
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
