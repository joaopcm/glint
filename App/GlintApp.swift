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
            SettingsView(settings: state.settings, bucket: state.bucket, history: state.history)
        }
    }
}

@MainActor
final class AppState {
    let settings = GlintSettings(
        store: UserDefaultsStore(),
        defaultSaveFolder: FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    )
    let bucket: BucketAccess
    let history: UploadHistory
    private let coordinator: CaptureCoordinator
    private let textCapture: TextCapture
    private let thumbnail: ThumbnailPresenter

    init() {
        let bucket = BucketAccess(settings: settings, credentialStore: Self.bucketCredentialStore(), transport: URLSessionS3Transport())
        self.bucket = bucket
        let toast = ToastPresenter()
        let history = UploadHistory(file: Self.uploadHistoryFile())
        self.history = history
        let thumbnail = ThumbnailPresenter(
            settings: settings,
            upload: { try await bucket.upload($0) },
            onUploaded: { uploaded in
                history.add(uploaded)
                do {
                    try NSPasteboard.general.copyText(uploaded.link.absoluteString)
                    toast.show("Link copied")
                } catch {
                    toast.show("Uploaded, but the clipboard refused the link: \(error.localizedDescription)")
                }
            }
        )
        self.thumbnail = thumbnail
        let capturer = ScreenCapturer()
        let coordinator = CaptureCoordinator(
            capturer: capturer,
            selector: SelectionOverlayController(snapshot: { try await capturer.captureDisplay($0) }),
            alerts: NSAlertPresenter(),
            settings: settings,
            onSaved: { thumbnail.show($0) }
        )
        self.coordinator = coordinator
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

    private static func bucketCredentialStore() -> any CredentialStore {
        #if DEBUG
        if let uiTestKeys = EnvironmentCredentialStore(environment: ProcessInfo.processInfo.environment) {
            return uiTestKeys
        }
        #endif
        return KeychainCredentialStore(service: KeychainCredentialStore.bucketService)
    }

    private static func uploadHistoryFile() -> URL {
        #if DEBUG
        if let uiTestFile = ProcessInfo.processInfo.environment["GLINT_UI_TEST_UPLOAD_HISTORY"] {
            return URL(filePath: uiTestFile)
        }
        #endif
        return URL.applicationSupportDirectory.appending(path: "Glint/upload-history.json")
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
