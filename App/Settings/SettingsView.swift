import AppKit
import GlintCore
import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    let settings: GlintSettings
    let bucket: BucketAccess
    let history: UploadHistory
    @State private var maxContentHeight: CGFloat?

    var body: some View {
        TabView {
            GeneralSettingsView(settings: settings)
                .fitsSettingsWindowOnScreen(maxHeight: maxContentHeight)
                .tabItem { Label("General", systemImage: "gearshape") }
            ShortcutsSettingsView()
                .fitsSettingsWindowOnScreen(maxHeight: maxContentHeight)
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            UploadSettingsView(bucket: bucket)
                .fitsSettingsWindowOnScreen(maxHeight: maxContentHeight)
                .tabItem { Label("Upload", systemImage: "icloud.and.arrow.up") }
            UploadHistoryView(history: history, bucket: bucket)
                .fitsSettingsWindowOnScreen(maxHeight: maxContentHeight)
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
        }
        .background(SettingsWindowFitter(maxContentHeight: $maxContentHeight))
    }
}

private struct GeneralSettingsView: View {
    @Bindable var settings: GlintSettings
    @State private var openAtLogin = OpenAtLogin()

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: Binding(get: { openAtLogin.isOn }, set: { openAtLogin.set($0) }))
                if openAtLogin.needsApproval {
                    LabeledContent {
                        Button("Open Login Items", action: openAtLogin.openLoginItems)
                    } label: {
                        Text(OpenAtLogin.approvalNote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let failure = openAtLogin.failure {
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            LabeledContent("Save folder") {
                HStack {
                    Text(settings.saveFolder.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Button("Choose…", action: chooseFolder)
                }
            }
            Toggle("Copy to clipboard after capture", isOn: $settings.copyToClipboardAfterCapture)
            Picker("Thumbnail corner", selection: $settings.overlayCorner) {
                Text("Bottom left").tag(OverlayCorner.bottomLeft)
                Text("Bottom right").tag(OverlayCorner.bottomRight)
            }
            Toggle("Hide thumbnail after a few seconds", isOn: $settings.overlayAutoDismiss)
            Toggle("Freeze screen while selecting", isOn: $settings.freezeScreenWhileSelecting)
            Picker("Recording format", selection: $settings.recordingCodec) {
                Text("H.264").tag(VideoCodec.h264)
                Text("HEVC").tag(VideoCodec.hevc)
            }
        }
        .onAppear(perform: openAtLogin.refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in openAtLogin.refresh() }
        .formStyle(.grouped)
        .frame(width: 480)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.saveFolder
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.saveFolder = url
    }
}

private struct ShortcutsSettingsView: View {
    @State private var shortcuts = ShortcutBindings(names: GlintShortcuts.all.map(\.name))

    var body: some View {
        Form {
            ForEach(GlintShortcuts.all, id: \.name) { title, name in
                ShortcutRecorder(
                    title: title,
                    allNames: shortcuts.names,
                    shortcut: shortcuts.shortcuts[name],
                    onChange: { shortcuts.set($0, for: name) },
                    usedBy: { recorded in
                        GlintShortcuts.all.first { $0.name != name && shortcuts.shortcuts[$0.name] == recorded }?.title
                    }
                )
            }
            HStack {
                Spacer()
                if shortcuts.canUndoRestore {
                    Button("Undo", action: shortcuts.undoRestore)
                        .accessibilityLabel("Undo Restore Defaults")
                }
                Button("Restore Defaults", action: shortcuts.restoreDefaults)
                    .disabled(shortcuts.areDefaults)
                    .accessibilityIdentifier(AccessibilityID.restoreDefaultShortcuts)
            }
        }
        .onAppear(perform: shortcuts.reload)
        .formStyle(.grouped)
        .frame(width: 480)
    }
}
