import AppKit
import GlintCore
import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    let settings: GlintSettings
    @State private var saveFolder: URL
    @State private var copyToClipboard: Bool
    @State private var overlayCorner: OverlayCorner
    @State private var overlayAutoDismiss: Bool

    init(settings: GlintSettings) {
        self.settings = settings
        _saveFolder = State(initialValue: settings.saveFolder)
        _copyToClipboard = State(initialValue: settings.copyToClipboardAfterCapture)
        _overlayCorner = State(initialValue: settings.overlayCorner)
        _overlayAutoDismiss = State(initialValue: settings.overlayAutoDismiss)
    }

    var body: some View {
        Form {
            LabeledContent("Save folder") {
                HStack {
                    Text(saveFolder.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Button("Choose…", action: chooseFolder)
                }
            }
            Toggle("Copy to clipboard after capture", isOn: $copyToClipboard)
                .onChange(of: copyToClipboard) { _, value in
                    settings.copyToClipboardAfterCapture = value
                }
            Picker("Thumbnail corner", selection: $overlayCorner) {
                Text("Bottom left").tag(OverlayCorner.bottomLeft)
                Text("Bottom right").tag(OverlayCorner.bottomRight)
            }
            .onChange(of: overlayCorner) { _, value in settings.overlayCorner = value }
            Toggle("Hide thumbnail after a few seconds", isOn: $overlayAutoDismiss)
                .onChange(of: overlayAutoDismiss) { _, value in settings.overlayAutoDismiss = value }
            KeyboardShortcuts.Recorder("Capture Area", name: .captureArea)
            KeyboardShortcuts.Recorder("Capture Window", name: .captureWindow)
            KeyboardShortcuts.Recorder("Capture Full Screen", name: .captureFullScreen)
            KeyboardShortcuts.Recorder("Capture Text", name: .captureText)
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = saveFolder
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        saveFolder = url
        settings.saveFolder = url
    }
}
