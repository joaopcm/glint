import AppKit
import GlintCore
import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    let settings: GlintSettings
    let bucket: BucketAccess
    let history: UploadHistory

    var body: some View {
        TabView {
            GeneralSettingsView(settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }
            UploadSettingsView(bucket: bucket)
                .tabItem { Label("Upload", systemImage: "icloud.and.arrow.up") }
            UploadHistoryView(history: history, bucket: bucket)
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
        }
    }
}

private struct GeneralSettingsView: View {
    @Bindable var settings: GlintSettings

    private static let shortcuts: [(title: String, name: KeyboardShortcuts.Name)] = [
        ("Capture Area", .captureArea),
        ("Capture Window", .captureWindow),
        ("Capture Full Screen", .captureFullScreen),
        ("Capture Text", .captureText),
        ("Record Area", .recordArea),
        ("Record Window", .recordWindow),
    ]

    var body: some View {
        Form {
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
            ForEach(Self.shortcuts, id: \.name) { title, name in
                ShortcutRecorder(title: title, name: name, allNames: Self.shortcuts.map(\.name)) { recorded in
                    Self.shortcuts.first { $0.name != name && KeyboardShortcuts.getShortcut(for: $0.name) == recorded }?.title
                }
            }
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
        panel.directoryURL = settings.saveFolder
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.saveFolder = url
    }
}
