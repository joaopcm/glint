import AppKit
import LunettaCore
import QuartzCore

/// Pulses a soft disc under the pointer on each click inside the recorded area. ScreenCaptureKit's own `showMouseClicks`
/// drew nothing in Lunetta's area recordings (an SCRecordingOutput stream that leaves out Lunetta's windows), and
/// tinycap saw the same with that setup (https://github.com/soleo/tinycap/pull/7). A global monitor sees other
/// apps' clicks without any permission; only key events need one.
@MainActor
final class ClickRingOverlay: ClickShowing {
    static let diameter = CGFloat(OverlayStyle.clickDiameter)
    static let fillAlpha = CGFloat(OverlayStyle.clickFillAlpha)

    private var panel: NSPanel?
    private var monitor: Any?

    func show(over region: CGRect, excludedFromCapture: Bool) {
        hide()
        let panel = Self.makePanel(over: region)
        if excludedFromCapture { CaptureChrome.mark(panel) }
        panel.orderFrontRegardless()
        self.panel = panel
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            // Events outside any window carry their location in screen coordinates.
            let location = event.locationInWindow
            MainActor.assumeIsolated { self?.ring(at: location) }
        }
    }

    func hide() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let panel { CaptureChrome.unmark(panel) }
        panel?.orderOut(nil)
        panel = nil
    }

    private func ring(at location: CGPoint) {
        guard let panel, panel.frame.contains(location), let host = panel.contentView?.layer else { return }
        let center = CGPoint(x: location.x - panel.frame.minX, y: location.y - panel.frame.minY)
        let pulse = Self.makePulse(centeredAt: center)
        host.addSublayer(pulse)
        CATransaction.begin()
        CATransaction.setCompletionBlock { pulse.removeFromSuperlayer() }
        pulse.add(Self.pulse(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion), forKey: "click")
        CATransaction.commit()
    }

    /// A borderless, see-through disc, so whatever sits under the pointer stays readable while it pulses.
    static func makePulse(centeredAt center: CGPoint) -> CAShapeLayer {
        let pulse = CAShapeLayer()
        pulse.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        pulse.position = center
        pulse.path = CGPath(ellipseIn: pulse.bounds, transform: nil)
        pulse.fillColor = NSColor.controlAccentColor.withAlphaComponent(fillAlpha).cgColor
        pulse.strokeColor = nil
        pulse.opacity = 0
        return pulse
    }

    /// Spreads out from the click while it fades, over the time a thumbnail takes to come and go.
    static func pulse(reduceMotion: Bool) -> CAAnimationGroup {
        let duration = OverlayStyle.clickPulseDuration
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = duration
        fade.timingFunction = ThumbnailPresenter.easeOut
        let group = CAAnimationGroup()
        if reduceMotion {
            group.animations = [fade]
        } else {
            let spread = CABasicAnimation(keyPath: "transform.scale")
            spread.fromValue = OverlayStyle.clickStartScale
            spread.toValue = 1
            spread.duration = duration
            spread.timingFunction = ThumbnailPresenter.easeOut
            group.animations = [spread, fade]
        }
        group.duration = duration
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
