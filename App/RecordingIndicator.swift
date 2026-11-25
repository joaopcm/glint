import AppKit
import LunettaCore

/// While a recording runs: a border just outside the recorded region and a stop button in the menu bar.
/// Both are Lunetta windows, which ScreenCapturer leaves out of every recording.
@MainActor
final class RecordingIndicator {
    static let borderWidth: CGFloat = 2

    var onStop: (@MainActor () -> Void)?
    private var border: NSPanel?
    private var stopItem: NSStatusItem?

    func update(region: CGRect?) {
        guard let region else { return hide() }
        show(around: region)
    }

    private func show(around region: CGRect) {
        let border = NSPanel(
            contentRect: RecordingGeometry.borderFrame(around: region, lineWidth: Self.borderWidth),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        border.level = .statusBar
        border.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        border.isOpaque = false
        border.backgroundColor = .clear
        border.hasShadow = false
        border.ignoresMouseEvents = true
        border.hidesOnDeactivate = false
        border.isReleasedWhenClosed = false
        let view = NSView()
        view.wantsLayer = true
        view.layer?.borderWidth = Self.borderWidth
        view.layer?.borderColor = NSColor.systemRed.cgColor
        border.contentView = view
        border.orderFrontRegardless()
        self.border = border

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop Recording")
            button.contentTintColor = .systemRed
            button.toolTip = "Stop Recording"
            button.target = self
            button.action = #selector(stop)
            button.setAccessibilityIdentifier(AccessibilityID.stopRecording)
        }
        stopItem = item
    }

    private func hide() {
        border?.orderOut(nil)
        border = nil
        if let stopItem { NSStatusBar.system.removeStatusItem(stopItem) }
        stopItem = nil
    }

    @objc private func stop() {
        onStop?()
    }
}
