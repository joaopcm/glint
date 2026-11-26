import AppKit
import CoreGraphics
import LunettaCore

/// Draws each key press near the bottom of the recorded area. Reading keys from other apps takes a listen-only event
/// tap, which needs Input Monitoring: the narrowest permission that sees the keyboard, since it can't post events
/// the way an Accessibility-trusted app can.
@MainActor
final class KeystrokeOverlay: KeystrokeShowing {
    /// 1.5 s after the last press: six times the 0.25 s one word takes at 238 wpm (Brysbaert 2019,
    /// doi:10.1016/j.jml.2019.104047), so someone watching the action, not the label, still catches it.
    private static let linger: Duration = .milliseconds(1500)
    private static let height: CGFloat = 52
    private static let bottomInset: CGFloat = 24

    private var panel: NSPanel?
    private var capsule: NSView?
    private var label: NSTextField?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var fading: Task<Void, Never>?

    var isAllowed: Bool { CGPreflightListenEventAccess() }

    func openSettings() {
        // Asking is what adds Lunetta to the Input Monitoring list; without it the user has to add Lunetta by hand.
        _ = CGRequestListenEventAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

    func show(over region: CGRect) throws {
        hide()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: keystrokeTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { throw RecordingProblem.inputMonitoringDenied }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.tap = tap
        self.source = source
        let panel = makePanel(over: region)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        fading?.cancel()
        fading = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        panel?.orderOut(nil)
        panel = nil
        capsule = nil
        label = nil
    }

    fileprivate func handle(_ type: CGEventType, keyCode: Int, characters: String?, flags: CGEventFlags) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown:
            guard let text = KeystrokeLabel.text(keyCode: keyCode, characters: characters, modifiers: Self.modifiers(flags)) else { return }
            present(text)
        default:
            break
        }
    }

    private func present(_ text: String) {
        guard let capsule, let label else { return }
        label.stringValue = text
        capsule.alphaValue = 1
        fading?.cancel()
        fading = Task { [weak self] in
            try? await Task.sleep(for: Self.linger)
            guard !Task.isCancelled, let capsule = self?.capsule else { return }
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = ThumbnailPresenter.exitDuration
                capsule.animator().alphaValue = 0
            }
        }
    }

    private static func modifiers(_ flags: CGEventFlags) -> KeyModifiers {
        let pairs: [(CGEventFlags, KeyModifiers)] = [(.maskControl, .control), (.maskAlternate, .option), (.maskShift, .shift), (.maskCommand, .command)]
        return pairs.reduce(into: KeyModifiers()) { modifiers, pair in
            if flags.contains(pair.0) { modifiers.insert(pair.1) }
        }
    }

    /// A strip along the bottom of the area, so the keys sit inside the recording whatever the area's size.
    private func makePanel(over region: CGRect) -> NSPanel {
        let frame = CGRect(x: region.minX, y: region.minY + Self.bottomInset, width: region.width, height: Self.height)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        let label = NSTextField(labelWithString: "")
        let base = NSFont.systemFont(ofSize: 22, weight: .semibold)
        label.font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 22) } ?? base
        label.textColor = .white
        label.lineBreakMode = .byTruncatingHead
        label.setAccessibilityIdentifier(AccessibilityID.pressedKeys)
        label.translatesAutoresizingMaskIntoConstraints = false
        // Dark on any background: the label has to read in the video over whatever is being recorded.
        let capsule = NSView()
        capsule.wantsLayer = true
        capsule.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        capsule.layer?.cornerRadius = 12
        capsule.layer?.cornerCurve = .continuous
        capsule.alphaValue = 0
        capsule.translatesAutoresizingMaskIntoConstraints = false
        capsule.addSubview(label)
        let content = NSView(frame: CGRect(origin: .zero, size: frame.size))
        content.addSubview(capsule)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: capsule.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: capsule.centerYAnchor),
            capsule.widthAnchor.constraint(equalTo: label.widthAnchor, constant: 28),
            capsule.heightAnchor.constraint(equalTo: content.heightAnchor),
            capsule.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            capsule.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            capsule.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor),
        ])
        panel.contentView = content
        self.capsule = capsule
        self.label = label
        return panel
    }
}

/// The tap's run loop source sits on the main run loop, so every call arrives on the main thread.
private func keystrokeTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    info: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let info else { return Unmanaged.passUnretained(event) }
    let overlay = Unmanaged<KeystrokeOverlay>.fromOpaque(info).takeUnretainedValue()
    let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
    let flags = event.flags
    nonisolated(unsafe) let pressed = event
    MainActor.assumeIsolated {
        let characters = type == .keyDown ? NSEvent(cgEvent: pressed)?.charactersIgnoringModifiers : nil
        overlay.handle(type, keyCode: keyCode, characters: characters, flags: flags)
    }
    return Unmanaged.passUnretained(event)
}
