import AppKit
import KeyboardShortcuts
import SwiftUI

struct ShortcutRecorder: View {
    let title: String
    let allNames: [KeyboardShortcuts.Name]
    let shortcut: KeyboardShortcuts.Shortcut?
    let onChange: (KeyboardShortcuts.Shortcut?) -> Void
    let usedBy: (KeyboardShortcuts.Shortcut) -> String?

    @State private var isRecording = false
    @State private var problem: String?

    var body: some View {
        LabeledContent(title) {
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 4) {
                    ShortcutKeyField(
                        label: isRecording ? "Press shortcut…" : shortcut.map(ShortcutKeyPress.label) ?? "Record Shortcut",
                        isRecording: isRecording,
                        onStart: startRecording,
                        onKey: handleKey,
                        onEnd: stopRecording
                    )
                    .frame(width: 150)
                    Button("Clear \(title) shortcut", systemImage: "xmark.circle.fill") {
                        stopRecording()
                        onChange(nil)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .opacity(shortcut == nil || isRecording ? 0 : 1)
                    .disabled(shortcut == nil || isRecording)
                }
                if let problem {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func startRecording() {
        problem = nil
        isRecording = true
        KeyboardShortcuts.disable(allNames)
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        problem = nil
        KeyboardShortcuts.enable(allNames)
    }

    private func handleKey(keyCode: Int, modifierFlags: NSEvent.ModifierFlags) {
        switch ShortcutKeyPress.interpret(keyCode: keyCode, modifierFlags: modifierFlags, usedBy: usedBy) {
        case .cancel:
            stopRecording()
        case .clear:
            stopRecording()
            onChange(nil)
        case .record(let recorded):
            stopRecording()
            onChange(recorded)
        case .reject(let message):
            problem = message
        }
    }
}

/// A button, not `NSSearchField`: a field editor ends and restarts editing on macOS 26+, which is what dropped every
/// key in `KeyboardShortcuts.Recorder` (sindresorhus/KeyboardShortcuts#241, #82).
private struct ShortcutKeyField: NSViewRepresentable {
    let label: String
    let isRecording: Bool
    let onStart: () -> Void
    let onKey: (Int, NSEvent.ModifierFlags) -> Void
    let onEnd: () -> Void

    func makeNSView(context: Context) -> KeyCaptureButton {
        let button = KeyCaptureButton()
        button.bezelStyle = .push
        button.target = button
        button.action = #selector(KeyCaptureButton.clicked)
        return button
    }

    func updateNSView(_ button: KeyCaptureButton, context: Context) {
        button.title = label
        button.onStart = onStart
        button.onKey = onKey
        button.onEnd = onEnd
        guard button.isRecording != isRecording else { return }
        button.isRecording = isRecording
        if isRecording {
            button.window?.makeFirstResponder(button)
        } else if button.window?.firstResponder === button {
            button.window?.makeFirstResponder(nil)
        }
    }
}

final class KeyCaptureButton: NSButton {
    var isRecording = false
    var onStart: () -> Void = {}
    var onKey: (Int, NSEvent.ModifierFlags) -> Void = { _, _ in }
    var onEnd: () -> Void = {}
    private var resignKeyObserver: NSObjectProtocol?

    override var acceptsFirstResponder: Bool { isRecording }

    @objc func clicked() {
        guard !isRecording else { return }
        onStart()
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return super.keyDown(with: event) }
        onKey(Int(event.keyCode), event.modifierFlags)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        onKey(Int(event.keyCode), event.modifierFlags)
        return true
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, isRecording { onEnd() }
        return resigned
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resignKeyObserver.map(NotificationCenter.default.removeObserver)
        resignKeyObserver = window.map { window in
            NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isRecording else { return }
                    self.onEnd()
                }
            }
        }
    }

    override func accessibilityValue() -> Any? { title }
}
