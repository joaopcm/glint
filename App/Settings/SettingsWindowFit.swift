import AppKit
import SwiftUI

// Sized to its content, Settings grew past the bottom of the 1024x768 CI screen: Restore Defaults at y 710 (run 45609327449),
// Test Connection at y 751 (run 45616804705), the connection rows at y 738-786 (run 45635710585). Every tab is capped at
// the screen's visible height and scrolls past it, and the window moves back up when a taller tab grows it off screen.
extension View {
    func fitsSettingsWindowOnScreen(maxHeight: CGFloat?) -> some View {
        CappedHeightLayout(maxHeight: maxHeight) { self }
    }
}

enum SettingsWindowPlacement {
    static func fitted(_ frame: CGRect, in visible: CGRect) -> CGRect {
        var fitted = frame
        fitted.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        return fitted
    }
}

private struct CappedHeightLayout: Layout {
    let maxHeight: CGFloat?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = subviews.first?.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) ?? .zero
        return CGSize(width: ideal.width, height: min(ideal.height, maxHeight ?? .infinity))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

struct SettingsWindowFitter: NSViewRepresentable {
    @Binding var maxContentHeight: CGFloat?

    func makeNSView(context: Context) -> NSView { WindowObservingView(onChange: fit) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private func fit(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let chrome = window.frame.height - window.contentLayoutRect.height
        let height = screen.visibleFrame.height - chrome
        if maxContentHeight != height { maxContentHeight = height }
        let fitted = SettingsWindowPlacement.fitted(window.frame, in: screen.visibleFrame)
        if fitted != window.frame { window.setFrame(fitted, display: true) }
    }

    final class WindowObservingView: NSView {
        let onChange: (NSWindow) -> Void
        private var observers: [any NSObjectProtocol] = []

        init(onChange: @escaping (NSWindow) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            observers = [NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification].map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                }
            }
            DispatchQueue.main.async { [weak self] in self?.report() }
        }

        private func report() {
            guard let window else { return }
            onChange(window)
        }
    }
}
