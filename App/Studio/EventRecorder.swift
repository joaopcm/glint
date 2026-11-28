import AppKit
import LunettaCore
import QuartzCore

@MainActor
final class EventRecorder {
    private let writer: CaptureEventWriter
    private let cursors: CursorImageStore
    private let windowID: UInt32?
    private let now: () -> Double
    private let pointer: () -> CGPoint
    private let cursor: () -> NSCursor?
    private let windowFrame: (UInt32) -> CGRect?

    private var lastPointer: CGPoint?
    private var lastCursor: NSCursor?
    private var lastShape: CursorShape?
    private var lastWindowFrame: CGRect?
    private var monitors: [Any] = []
    private var link: CADisplayLink?
    private var failure: Error?

    init(
        writer: CaptureEventWriter,
        cursors: CursorImageStore,
        windowID: UInt32?,
        now: @escaping () -> Double = CACurrentMediaTime,
        pointer: @escaping () -> CGPoint = { NSEvent.mouseLocation },
        cursor: @escaping () -> NSCursor? = { NSCursor.currentSystem },
        windowFrame: @escaping (UInt32) -> CGRect? = EventRecorder.windowFrame
    ) {
        self.writer = writer
        self.cursors = cursors
        self.windowID = windowID
        self.now = now
        self.pointer = pointer
        self.cursor = cursor
        self.windowFrame = windowFrame
    }

    func start() {
        let buttons: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: buttons, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.logClick() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: buttons, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.logClick() }
            return event
        }) {
            monitors.append(local)
        }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let target = TickTarget(recorder: self)
        let link = screen.displayLink(target: target, selector: #selector(TickTarget.tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func tick() {
        let location = pointer()
        if location != lastPointer {
            lastPointer = location
            record(.pointer(t: now(), x: location.x, y: location.y))
        }
        logCursorChange()
        if let windowID, let frame = windowFrame(windowID), frame != lastWindowFrame {
            lastWindowFrame = frame
            record(.window(t: now(), frame: frame))
        }
    }

    func logKey(_ label: String) {
        record(.key(t: now(), label: label))
    }

    func logBubble(_ frame: CGRect) {
        record(.bubble(t: now(), frame: frame))
    }

    func stop() throws {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        link?.invalidate()
        link = nil
        try writer.close()
        if let failure { throw failure }
    }

    nonisolated static func windowFrame(of id: UInt32) -> CGRect? {
        guard let descriptions = CGWindowListCreateDescriptionFromArray([id] as CFArray) as? [[CFString: Any]],
              let bounds = descriptions.first?[kCGWindowBounds] as? [String: CGFloat]
        else { return nil }
        let topLeft = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
        return DisplayGeometry.appKitRect(fromTopLeftGlobal: topLeft, mainDisplayHeight: CGDisplayBounds(CGMainDisplayID()).height)
    }

    private func logClick() {
        let location = pointer()
        record(.click(t: now(), x: location.x, y: location.y))
    }

    private func logCursorChange() {
        guard let current = cursor(), current !== lastCursor, current != lastCursor else { return }
        lastCursor = current
        do {
            let shape = CursorShape(image: try cursors.name(for: current), hotspot: current.hotSpot)
            guard shape != lastShape else { return }
            lastShape = shape
            record(.cursor(t: now(), image: shape.image, hotspotX: shape.hotspot.x, hotspotY: shape.hotspot.y))
        } catch {
            failure = failure ?? error
        }
    }

    private func record(_ event: CaptureEvent) {
        do {
            try writer.append(event)
        } catch {
            failure = failure ?? error
        }
    }
}

@MainActor
private final class TickTarget: NSObject {
    private weak var recorder: EventRecorder?

    init(recorder: EventRecorder) {
        self.recorder = recorder
    }

    @objc func tick() {
        recorder?.tick()
    }
}
