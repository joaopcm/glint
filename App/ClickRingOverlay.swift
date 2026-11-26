import AppKit
import QuartzCore

/// Draws a ring under the pointer on each click inside the recorded area. ScreenCaptureKit's own `showMouseClicks`
/// drew nothing in Lunetta's area recordings (an SCRecordingOutput stream that leaves out Lunetta's windows), and
/// tinycap saw the same with that setup (https://github.com/soleo/tinycap/pull/7). A global monitor sees other
/// apps' clicks without any permission; only key events need one.
@MainActor
final class ClickRingOverlay: ClickShowing {
    private static let diameter: CGFloat = 36
    private static let lineWidth: CGFloat = 3

    private var panel: NSPanel?
    private var monitor: Any?

    func show(over region: CGRect) -> UInt32 {
        hide()
        let panel = Self.makePanel(over: region)
        // On screen before the recording starts: ScreenCaptureKit only keeps windows it lists, and it lists on-screen ones.
        panel.orderFrontRegardless()
        self.panel = panel
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            // Events outside any window carry their location in screen coordinates.
            let location = event.locationInWindow
            MainActor.assumeIsolated { self?.ring(at: location) }
        }
        return UInt32(panel.windowNumber)
    }

    func hide() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func ring(at location: CGPoint) {
        guard let panel, panel.frame.contains(location), let host = panel.contentView?.layer else { return }
        let center = CGPoint(x: location.x - panel.frame.minX, y: location.y - panel.frame.minY)
        let ring = Self.makeRing(centeredAt: center)
        host.addSublayer(ring)
        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        ring.add(Self.fadeAway(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion), forKey: "click")
        CATransaction.commit()
    }

    private static func makeRing(centeredAt center: CGPoint) -> CAShapeLayer {
        let ring = CAShapeLayer()
        ring.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        ring.position = center
        ring.path = CGPath(ellipseIn: ring.bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2), transform: nil)
        let accent = NSColor.controlAccentColor
        ring.fillColor = accent.withAlphaComponent(0.3).cgColor
        ring.strokeColor = accent.cgColor
        ring.lineWidth = lineWidth
        ring.opacity = 0
        return ring
    }

    /// Grows in like a thumbnail enters, then fades like one leaves.
    private static func fadeAway(reduceMotion: Bool) -> CAAnimationGroup {
        let enter = ThumbnailPresenter.enterDuration
        let exit = ThumbnailPresenter.exitDuration
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.beginTime = enter
        fade.duration = exit
        fade.fillMode = .backwards
        fade.timingFunction = ThumbnailPresenter.easeOut
        let group = CAAnimationGroup()
        if reduceMotion {
            group.animations = [fade]
        } else {
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 0.5
            grow.toValue = 1
            grow.duration = enter
            grow.timingFunction = ThumbnailPresenter.easeOut
            group.animations = [grow, fade]
        }
        group.duration = enter + exit
        return group
    }

    private static func makePanel(over region: CGRect) -> NSPanel {
        let panel = NSPanel(contentRect: region, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let content = NSView(frame: CGRect(origin: .zero, size: region.size))
        content.wantsLayer = true
        panel.contentView = content
        return panel
    }
}
