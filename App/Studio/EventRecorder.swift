import AppKit
import LunettaCore
import QuartzCore

enum EventRecorderError: Error, LocalizedError {
    case noScreen

    var errorDescription: String? {
        "No screen to drive the event recorder's display link, so pointer and cursor changes were not logged."
    }
}

@MainActor
final class EventRecorder {
    private let writer: CaptureEventWriter
    private let cursors: CursorImageStore
    private let windowID: UInt32?
    private let now: () -> Double
    private let pointer: () -> CGPoint
    private let cursor: () -> NSCursor?
    private let windowFrame: (UInt32) -> CGRect?

    private var lastPointer: (point: CGPoint, t: Double)?
    private var lastTick: Double?
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
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            failure = failure ?? EventRecorderError.noScreen
            return
        }
        let target = TickTarget(recorder: self)
        let link = screen.displayLink(target: target, selector: #selector(TickTarget.tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// The log only says where the pointer went, and a reader draws it gliding from one sample to the next. A pointer
    /// that rested gets the resting point again at the last tick before it moved, so it holds still until then.
    func tick() {
        let t = now()
        let location = pointer()
        if location != lastPointer?.point {
            if let held = lastPointer, let lastTick, lastTick > held.t {
                record(.pointer(t: lastTick, x: held.point.x, y: held.point.y))
            }
            lastPointer = (location, t)
            record(.pointer(t: t, x: location.x, y: location.y))
        }
        lastTick = t
        logCursorChange(at: t)
        if let windowID, let frame = windowFrame(windowID), frame != lastWindowFrame {
            lastWindowFrame = frame
            record(.window(t: t, frame: frame))
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

    private func logCursorChange(at t: Double) {
        guard let current = cursor() else { return }
        do {
            let shape = CursorShape(image: try cursors.name(for: current), hotspot: current.hotSpot)
            guard shape != lastShape else { return }
            lastShape = shape
            record(.cursor(t: t, image: shape.image, hotspotX: shape.hotspot.x, hotspotY: shape.hotspot.y))
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
