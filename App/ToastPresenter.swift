import AppKit

@MainActor
final class ToastPresenter {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let visibleFor: Duration
    private let pointerLocation: @MainActor () -> CGPoint
    private var hideTask: Task<Void, Never>?

    // "Copied 12 lines" is 3 words, 0.76 s at the 238 wpm adult silent reading rate (Brysbaert 2019, doi:10.1016/j.jml.2019.104047).
    // 2 s leaves the rest for the eye to travel to the bottom of the screen.
    init(visibleFor: Duration = .seconds(2), pointerLocation: @escaping @MainActor () -> CGPoint = { NSEvent.mouseLocation }) {
        self.visibleFor = visibleFor
        self.pointerLocation = pointerLocation
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true

        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        label.setAccessibilityIdentifier(AccessibilityID.toast)
        label.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: background.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -10),
        ])
        panel.contentView = background
    }

    var visibleMessage: String? {
        panel.isVisible ? label.stringValue : nil
    }

    func show(_ message: String) {
        present(message)
        hideTask = Task { [weak self, visibleFor] in
            do {
                try await Task.sleep(for: visibleFor)
            } catch {
                return
            }
            self?.panel.orderOut(nil)
        }
    }

    /// No timer: the private window picker prompt holds the capture for as long as the user takes to answer it.
    func showUntilHidden(_ message: String) {
        present(message)
    }

    func hide(_ message: String) {
        guard visibleMessage == message else { return }
        panel.orderOut(nil)
    }

    private func present(_ message: String) {
        label.stringValue = message
        let size = panel.contentView?.fittingSize ?? .zero
        let pointer = pointerLocation()
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            let origin = CGPoint(x: visible.midX - size.width / 2, y: visible.minY + ThumbnailPresenter.margin)
            panel.setFrame(CGRect(origin: origin, size: size), display: true)
        }
        panel.orderFrontRegardless()
        hideTask?.cancel()
        hideTask = nil
    }
}
