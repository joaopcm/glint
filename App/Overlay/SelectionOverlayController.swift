import AppKit
import Carbon.HIToolbox
import LunettaCapture
import LunettaCore
import os

@MainActor
final class SelectionOverlayController: Selecting {
    private var panels: [OverlayPanel] = []
    private var areaViews: [AreaSelectionView] = []
    private var windowViews: [WindowPickerView] = []
    private var continuation: CheckedContinuation<SelectionResult, any Error>?
    private var windowLoading: Task<Void, Never>?
    private var windowTargets: [WindowTarget]?
    private var pendingClick: CGPoint?
    private var highlightedWindow: WindowTarget?
    private var snapshotTasks: [Task<Void, Never>] = []
    private let showsMagnifier: @MainActor () -> Bool
    private let snapshot: @Sendable (DisplayInfo) async throws -> CGImage
    private let log = Logger(subsystem: "com.joaopcm.lunetta", category: "loupe")

    init(showsMagnifier: @escaping @MainActor () -> Bool, snapshot: @escaping @Sendable (DisplayInfo) async throws -> CGImage) {
        self.showsMagnifier = showsMagnifier
        self.snapshot = snapshot
    }

    func selectArea(frozen: [FrozenDisplay]) async throws -> SelectionResult {
        let displays = DisplayInfo.onScreens()
        let showsLoupe = showsMagnifier()
        var views: [AreaSelectionView] = []
        return try await present { screen in
            let display = displays.first { $0.frame == screen.frame }
            let backdrop = frozen.first { $0.display.frame == screen.frame }?.image
            let view = AreaSelectionView(
                screenFrame: screen.frame, display: display, displays: displays, showsLoupe: showsLoupe, backdrop: backdrop
            )
            view.onSelectionChange = { [weak self] rect in self?.updateAreaSelection(rect) }
            view.onPointerMove = { [weak self] point in self?.updateLoupes(at: point) }
            view.onFinish = { [weak self] result in self?.finish(result) }
            views.append(view)
            return view
        } afterShowing: {
            areaViews = views
            loadSnapshots()
        }
    }

    private func loadSnapshots() {
        for view in areaViews where view.needsSnapshot {
            guard let display = view.display else { continue }
            let id = display.id
            snapshotTasks.append(Task { [weak self, weak view, snapshot, log] in
                do {
                    let image = try await snapshot(display)
                    guard !Task.isCancelled, let view, self?.areaViews.contains(where: { $0 === view }) == true else { return }
                    view.setSnapshot(image)
                } catch {
                    log.error("loupe snapshot failed for display \(id): \(error.localizedDescription, privacy: .public)")
                }
            })
        }
    }

    private func updateLoupes(at point: CGPoint) {
        for view in areaViews {
            view.updateLoupe(at: point)
        }
    }

    func selectWindow(_ windows: Task<[CapturableWindow], any Error>) async throws -> SelectionResult {
        var views: [WindowPickerView] = []
        return try await present { screen in
            let view = WindowPickerView(screenFrame: screen.frame)
            view.onPointerMove = { [weak self] point in self?.highlightWindow(at: point) }
            view.onClick = { [weak self] point in self?.pickWindow(at: point) }
            views.append(view)
            return view
        } afterShowing: {
            windowViews = views
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
        snapshotTasks.forEach { $0.cancel() }
        snapshotTasks = []
        panels.forEach { $0.orderOut(nil) }
        panels = []
        areaViews = []
        windowViews = []
        windowTargets = nil
        pendingClick = nil
        highlightedWindow = nil
        NSCursor.arrow.set()
        return continuation
    }

    private func updateAreaSelection(_ rect: CGRect?) {
        for view in areaViews {
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
        for view in windowViews {
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

extension NSEvent {
    /// Where the event happened, not where the pointer is now: on a busy main thread the two drift apart (run 45493012014 started a text selection 42 pt right of and 39 pt below the press).
    var screenLocation: CGPoint {
        window?.convertPoint(toScreen: locationInWindow) ?? locationInWindow
    }
}
