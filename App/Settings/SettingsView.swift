import AppKit
import LunettaCore
import KeyboardShortcuts
import SwiftUI

enum SettingsLayout {
    /// Every tab shares one width so the window doesn't jump sideways between tabs. 480 pt held the old 4 tabs;
    /// 560 pt gives 7 toolbar tabs room without a » overflow menu (SettingsTabsUITests clicks each one) and a padding
    /// preview big enough to judge.
    static let width: CGFloat = 560
}

struct SettingsView: View {
    let settings: LunettaSettings
    let bucket: BucketAccess
    let history: UploadHistory
    @State private var maxContentHeight: CGFloat?

    var body: some View {
        TabView {
            GeneralSettingsView(settings: settings)
                .fitsSettingsWindowOnScreen(maxHeight: maxContentHeight)
                .tabItem { Label("General", systemImage: "gearshape") }
            CaptureSettingsView(settings: settings)
                .fitsSettingsWindowOnScreen(maxHeight: maxContentHeight)
                .tabItem { Label("Capture", systemImage: "camera.viewfinder") }
            RecordingSettingsView(settings: settings)
                .fitsSettingsWindowOnScreen(maxHeight: maxContentHeight)
                .tabItem { Label("Recording", systemImage: "record.circle") }
            SoundsSettingsView(settings: settings)
                .fitsSettingsWindowOnScreen(maxHeight: maxContentHeight)
                .tabItem { Label("Sounds", systemImage: "speaker.wave.2") }
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
    @Bindable var settings: LunettaSettings
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
            Section("After capture") {
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
                Toggle(isOn: $settings.compressAfterCapture) {
                    Text("Compress after capture")
                    Text("Shrinks screenshots and recordings before they're copied or uploaded. Screenshots keep up to 256 colors, so photos in them can band a little.")
                }
            }
            Section("Clipboard") {
                Toggle(isOn: $settings.compressCopiedMedia) {
                    Text("Compress copied images and recordings")
                    Text("A PNG, TIFF or BMP image or a recording you copy in any app gets a thumbnail that compresses a copy of it, and the smaller copy replaces it on the clipboard. The file you copied stays as it is.")
                }
            }
            Section("Quick Access") {
                ThumbnailCornerPicker(corner: $settings.overlayCorner)
                Toggle(isOn: $settings.overlayAutoDismiss) {
                    Text("Hide thumbnail after a few seconds")
                    Text("Off keeps each thumbnail on screen until you close it.")
                }
            }
        }
        .onAppear(perform: openAtLogin.refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in openAtLogin.refresh() }
        .formStyle(.grouped)
        .frame(width: SettingsLayout.width)
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

private struct RecordingSettingsView: View {
    @Bindable var settings: LunettaSettings

    var body: some View {
        Form {
            Picker("Recording format", selection: $settings.recordingCodec) {
                Text("H.264").tag(VideoCodec.h264)
                Text("HEVC").tag(VideoCodec.hevc)
            }
            .accessibilityIdentifier(AccessibilityID.recordingFormat)
            Picker("Frame rate", selection: $settings.recordingFrameRate) {
                Text("30 fps").tag(RecordingFrameRate.thirty)
                Text("60 fps").tag(RecordingFrameRate.sixty)
            }
            .accessibilityIdentifier(AccessibilityID.recordingFrameRate)
            Toggle(isOn: $settings.capsRenderToUHD) {
                Text("Limit recordings to 4K")
                Text("Recordings of a bigger screen are scaled down to fit 3840 × 2160 when they render. Off keeps the screen's own size.")
            }
            Toggle(isOn: $settings.recordingCountdown) {
                Text("Count down before recording")
                Text("Counts down \(RecordingHUD.countdownSeconds) seconds over the area before the first frame.")
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsLayout.width)
    }
}

private struct ShortcutsSettingsView: View {
    @State private var shortcuts = ShortcutBindings(names: LunettaShortcuts.all.map(\.name))

    var body: some View {
        Form {
            ForEach(LunettaShortcuts.all, id: \.name) { title, name in
                ShortcutRecorder(
                    title: title,
                    allNames: shortcuts.names,
                    shortcut: shortcuts.shortcuts[name],
                    onChange: { shortcuts.set($0, for: name) },
                    usedBy: { recorded in
                        LunettaShortcuts.all.first { $0.name != name && shortcuts.shortcuts[$0.name] == recorded }?.title
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
        .frame(width: SettingsLayout.width)
    }
}
