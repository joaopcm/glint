import GlintCapture
import GlintCore
import KeyboardShortcuts
import SwiftUI

@main
struct GlintApp: App {
    private let state = AppState()

    var body: some Scene {
        MenuBarExtra("Glint", systemImage: "camera.viewfinder") {
            MenuContent(state: state)
            Button("Quit Glint") { NSApplication.shared.terminate(nil) }
        }
        Settings {
            SettingsView(settings: state.settings)
        }
    }
}

@MainActor
final class AppState {
    let settings = GlintSettings(
        store: UserDefaultsStore(),
        defaultSaveFolder: FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    )
    private let coordinator: CaptureCoordinator
    private let textCapture: TextCapture
    private let thumbnail: ThumbnailPresenter

    init() {
        let thumbnail = ThumbnailPresenter(settings: settings)
        self.thumbnail = thumbnail
        let coordinator = CaptureCoordinator(
            capturer: ScreenCapturer(),
            selector: SelectionOverlayController(),
            alerts: NSAlertPresenter(),
            settings: settings,
            onSaved: { thumbnail.show($0) }
        )
        self.coordinator = coordinator
        let toast = ToastPresenter()
        textCapture = TextCapture(
            captureImage: { await coordinator.captureImage(.area) },
            alerts: NSAlertPresenter(),
            onOutcome: { toast.show($0.message) }
        )
        let shortcuts: [(KeyboardShortcuts.Name, CaptureMode)] = [
            (.captureArea, .area),
            (.captureWindow, .window),
            (.captureFullScreen, .fullScreen),
        ]
        for (name, mode) in shortcuts {
            KeyboardShortcuts.onKeyDown(for: name) { [weak self] in self?.capture(mode) }
        }
        KeyboardShortcuts.onKeyDown(for: .captureText) { [weak self] in self?.captureText() }
    }

    func capture(_ mode: CaptureMode) {
        Task { await coordinator.run(mode) }
    }

    func captureText() {
        Task { await textCapture.run() }
    }
}

private struct MenuContent: View {
    let state: AppState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Capture Area") { state.capture(.area) }
        Button("Capture Window") { state.capture(.window) }
        Button("Capture Full Screen") { state.capture(.fullScreen) }
        Button("Capture Text") { state.captureText() }
        Divider()
        Button("Settings…") {
            NSApplication.shared.activate()
            openSettings()
        }
        .keyboardShortcut(",")
        Divider()
        Text(BuildInfo.label(from: Bundle.main.infoDictionary))
    }
}
