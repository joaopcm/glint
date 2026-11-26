import AppKit
import LunettaCore
import LunettaUI
import SwiftUI

/// What the panel shows besides the settings themselves: the inputs connected now and what would keep the choices
/// from recording. Permissions change in System Settings without telling Lunetta, so both are re-read on `refresh`.
@MainActor @Observable
final class RecordingPanelModel {
    private(set) var problems: [RecordingProblem] = []
    private(set) var connectedInputs: [AudioInput] = []
    let settings: LunettaSettings
    private let checkProblems: @MainActor (RecordingMode) -> [RecordingProblem]
    private let listInputs: @MainActor () -> [AudioInput]
    private let applyFix: @MainActor (RecordingFix) async -> Void

    init(
        settings: LunettaSettings,
        problems: @escaping @MainActor (RecordingMode) -> [RecordingProblem],
        inputs: @escaping @MainActor () -> [AudioInput],
        fix: @escaping @MainActor (RecordingFix) async -> Void
    ) {
        self.settings = settings
        checkProblems = problems
        listInputs = inputs
        applyFix = fix
    }

    /// A saved input that isn't connected stays listed, so the picker still shows what the panel complains about.
    var pickableInputs: [AudioInput] {
        guard let saved = settings.recordingInput, !connectedInputs.contains(saved) else { return connectedInputs }
        return connectedInputs + [saved]
    }

    func isConnected(_ input: AudioInput) -> Bool {
        connectedInputs.contains { $0.id == input.id }
    }

    func refresh() {
        connectedInputs = listInputs()
        problems = checkProblems(settings.recordingMode)
    }

    func fix(_ fix: RecordingFix) {
        Task {
            await applyFix(fix)
            refresh()
        }
    }
}

struct RecordingPanelView: View {
    @Bindable var settings: LunettaSettings
    let model: RecordingPanelModel
    let onRecord: @MainActor () -> Void
    let onCancel: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Record", selection: $settings.recordingMode) {
                Text("Area").tag(RecordingMode.area)
                Text("Window").tag(RecordingMode.window)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier(AccessibilityID.recordingPanelMode)

            VStack(alignment: .leading, spacing: 8) {
                Toggle("System Audio", isOn: $settings.recordSystemAudio)
                    .accessibilityIdentifier(AccessibilityID.recordingPanelSystemAudio)
                Toggle("Microphone", isOn: $settings.recordMicrophone)
                    .accessibilityIdentifier(AccessibilityID.recordingPanelMicrophone)
                Picker("Input", selection: inputID) {
                    Text("System Default").tag("")
                    ForEach(model.pickableInputs) { input in
                        Text(model.isConnected(input) ? input.name : "\(input.name) (not connected)").tag(input.id)
                    }
                }
                .disabled(!settings.recordMicrophone)
                .padding(.leading, 20)
                .accessibilityIdentifier(AccessibilityID.recordingPanelInput)
                Toggle("Show Pressed Keys", isOn: $settings.showPressedKeys)
                    .accessibilityIdentifier(AccessibilityID.recordingPanelPressedKeys)
                Toggle("Highlight Clicks", isOn: $settings.showMouseClicks)
                    .accessibilityIdentifier(AccessibilityID.recordingPanelClicks)
            }
            .toggleStyle(.checkbox)

            ForEach(model.problems, id: \.self) { problem in
                ProblemRow(problem: problem, fix: model.fix)
            }

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier(AccessibilityID.recordingPanelCancel)
                Spacer()
                Button("Record", action: onRecord)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.problems.isEmpty)
                    .accessibilityIdentifier(AccessibilityID.recordingPanelRecord)
            }
        }
        .padding(16)
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.recordingPanel)
        .onChange(of: settings.recordingChoices) { model.refresh() }
        .onChange(of: settings.recordingMode) { model.refresh() }
    }

    private var inputID: Binding<String> {
        Binding(
            get: { settings.recordingInput?.id ?? "" },
            set: { id in settings.recordingInput = model.pickableInputs.first { $0.id == id } }
        )
    }
}

private struct ProblemRow: View {
    let problem: RecordingProblem
    let fix: @MainActor (RecordingFix) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(problem.localizedDescription)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if let action = problem.fix {
                    Button(action.rawValue) { fix(action) }
                        .controlSize(.small)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.recordingPanelProblem)
    }
}

/// Floats above other windows without taking focus from the app being recorded, but still takes keys for Esc and Return.
private final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class RecordingPanel {
    private let model: RecordingPanelModel
    private let onRecord: @MainActor (RecordingMode) -> Void
    private var panel: FloatingPanel?
    private var keyObserver: (any NSObjectProtocol)?

    init(model: RecordingPanelModel, onRecord: @escaping @MainActor (RecordingMode) -> Void) {
        self.model = model
        self.onRecord = onRecord
    }

    func show() {
        model.refresh()
        let panel = panel ?? makePanel()
        self.panel = panel
        if !panel.isVisible { panel.setFrameOrigin(Self.origin(for: panel.frame.size)) }
        panel.makeKeyAndOrderFront(nil)
    }

    func refresh() {
        guard panel?.isVisible == true else { return }
        model.refresh()
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func record() {
        close()
        onRecord(model.settings.recordingMode)
    }

    private func makePanel() -> FloatingPanel {
        let view = RecordingPanelView(
            settings: model.settings,
            model: model,
            onRecord: { [weak self] in self?.record() },
            onCancel: { [weak self] in self?.close() }
        )
        let hosting = NSHostingView(rootView: view)
        let surface = Glass.surface(holding: hosting, cornerRadius: 16)
        let panel = FloatingPanel(
            contentRect: CGRect(origin: .zero, size: hosting.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = surface
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.refresh() }
        }
        return panel
    }

    /// Centered on the screen under the pointer, where the user's attention already is.
    private static func origin(for size: CGSize) -> CGPoint {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        return CGPoint(x: (visible.midX - size.width / 2).rounded(), y: (visible.midY - size.height / 2).rounded())
    }
}
