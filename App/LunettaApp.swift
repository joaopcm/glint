import AVFoundation
import LunettaCapture
import LunettaCore
import KeyboardShortcuts
import SwiftUI

@main
struct LunettaApp: App {
    private let state = AppState()

    var body: some Scene {
        MenuBarExtra("Lunetta", image: "MenuBarIcon") {
            MenuContent(state: state)
            Button("Quit Lunetta") { NSApplication.shared.terminate(nil) }
        }
        Settings {
            LazySettingsView(state: state)
        }
    }
}

private struct LazySettingsView: View {
    let state: AppState

    var body: some View {
        SettingsView(settings: state.settings, bucket: state.bucket, history: state.history)
    }
}

@MainActor
final class AppState {
    let settings = LunettaSettings(
        store: UserDefaultsStore(),
        defaultSaveFolder: FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    )
    lazy var bucket = BucketAccess(
        settings: settings,
        credentialStore: Self.bucketCredentialStore(),
        transport: URLSessionS3Transport()
    )
    lazy var history = UploadHistory(file: Self.uploadHistoryFile())
    private lazy var toast = ToastPresenter()
    private var coordinator: CaptureCoordinator!
    private var textCapture: TextCapture!
    private var thumbnail: ThumbnailPresenter!
    private var clipboardCompressor: ClipboardCompressor!
    private lazy var recordingHUD = RecordingHUD(settings: settings)
    private let microphone = SystemMicrophoneAccess()
    private let keystrokes = KeystrokeOverlay()
    private let clickRings = ClickRingOverlay()
    private lazy var recordingStage = RecordingStage(
        model: RecordingStageModel(
            settings: settings,
            problems: { [unowned self] in coordinator.recordingProblems(for: .area) },
            inputs: { [microphone] in microphone.inputs },
            fix: { [unowned self] fix in await coordinator.fix(fix) }
        )
    )
    private let shutterSound = ShutterSound()

    init() {
        #if DEBUG
        startRecordingChoicesOverForUITests()
        #endif
        thumbnail = ThumbnailPresenter(
            settings: settings,
            upload: { [weak self] url in
                guard let self else { throw UploadError.notConfigured }
                return try await self.bucket.upload(url)
            },
            onUploaded: { [weak self] uploaded in
                guard let self else { return }
                self.history.add(uploaded)
                do {
                    try NSPasteboard.general.copyText(uploaded.link.absoluteString)
                    self.toast.show("Link copied")
                } catch {
                    self.toast.show("Uploaded, but the clipboard refused the link: \(error.localizedDescription)")
                }
            }
        )
        clipboardCompressor = ClipboardCompressor(
            settings: settings,
            show: { [weak self] url, compression in
                self?.thumbnail.show(url, precomputedThumbnail: nil, compression: compression, isCapture: false)
            },
            onProblem: { [weak self] message in self?.toast.show(message) }
        )
        let capturer = ScreenCapturer(chromeWindowIDs: { await CaptureChrome.windowIDs() })
        let coordinator = CaptureCoordinator(
            capturer: capturer,
            recorder: capturer,
            microphone: microphone,
            keystrokes: keystrokes,
            clickRings: clickRings,
            stager: recordingStage,
            selector: SelectionOverlayController(
                showsMagnifier: { [settings] in settings.showMagnifierWhileSelecting },
                snapshot: { try await capturer.captureDisplay($0) }
            ),
            alerts: NSAlertPresenter(),
            settings: settings,
            playShutterSound: { [shutterSound] in shutterSound.play() },
            onSaved: { [weak self] url, precomputedThumbnail, compression in
                self?.thumbnail.show(url, precomputedThumbnail: precomputedThumbnail, compression: compression)
            },
            onRecordingEvent: { [weak self] event in self?.recordingHUD.handle(event) },
            countDown: { [weak self] status in await self?.recordingHUD.countDown(status) ?? true }
        )
        self.coordinator = coordinator
        recordingHUD.onStop = { Task { await coordinator.stopRecording() } }
        recordingHUD.onTogglePause = { Task { await coordinator.togglePause() } }
        recordingHUD.onDiscard = { Task { await coordinator.discardRecording() } }
        recordingHUD.onStartOver = { Task { await coordinator.startOverRecording() } }
        textCapture = TextCapture(
            captureImage: { await coordinator.captureImage(.area) },
            alerts: NSAlertPresenter(),
            onOutcome: { [weak self] outcome in self?.toast.show(outcome.message) }
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
        KeyboardShortcuts.onKeyDown(for: .recordArea) { [weak self] in self?.record(.area) }
        KeyboardShortcuts.onKeyDown(for: .recordWindow) { [weak self] in self?.record(.window) }
        KeyboardShortcuts.onKeyDown(for: .recordScreen) { [weak self] in self?.recordScreen() }
        watchInputs()
    }

    /// A recording's input going away ends it, and the stage's input menu follows what's plugged in.
    private func watchInputs() {
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            _ = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let disconnectedID = name == AVCaptureDevice.wasDisconnectedNotification ? (notification.object as? AVCaptureDevice)?.uniqueID : nil
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.recordingStage.refresh()
                    if let disconnectedID { Task { await self.coordinator.inputDisconnected(id: disconnectedID) } }
                }
            }
        }
    }

    #if DEBUG
    /// The stage's UI tests start from its first-run choices. They can't clear Lunetta's defaults themselves: the runner
    /// never saw what Lunetta saved there, through CFPreferences or `defaults` (runs 45816994479, 45822621052).
    private func startRecordingChoicesOverForUITests() {
        guard ProcessInfo.processInfo.environment["LUNETTA_UI_TEST_FRESH_RECORDING_CHOICES"] != nil else { return }
        settings.recordSystemAudio = false
        settings.recordMicrophone = false
        settings.recordingInput = nil
        settings.showPressedKeys = false
        settings.showMouseClicks = false
    }
    #endif

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
        if let uiTestFile = ProcessInfo.processInfo.environment["LUNETTA_UI_TEST_UPLOAD_HISTORY"] {
            return URL(filePath: uiTestFile)
        }
        #endif
        return URL.applicationSupportDirectory.appending(path: "Lunetta/upload-history.json")
    }

    func capture(_ mode: CaptureMode) {
        explainingPickerPromptOnFirstUse { await self.coordinator.run(mode) }
    }

    func captureText() {
        explainingPickerPromptOnFirstUse { await self.textCapture.run() }
    }

    /// Record Area and Record Window skip the stage and record with its last choices.
    func record(_ mode: RecordingMode) {
        explainingPickerPromptOnFirstUse { await self.coordinator.toggleRecording(mode) }
    }

    func recordScreen() {
        explainingPickerPromptOnFirstUse { await self.coordinator.toggleRecording(.area, staged: true) }
    }

    /// The toast stays until `work` returns: macOS holds the first ScreenCaptureKit call until the prompt is answered.
    private func explainingPickerPromptOnFirstUse(_ work: @escaping @MainActor () async -> Void) {
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let explains = PickerPromptNotice.shouldExplain(macOSMajor: major, alreadyExplained: settings.pickerPromptExplained)
        if explains {
            settings.pickerPromptExplained = true
            toast.showUntilHidden(PickerPromptNotice.message)
        }
        Task {
            await work()
            if explains { toast.hide(PickerPromptNotice.message) }
        }
    }
}

private struct MenuContent: View {
    let state: AppState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Capture Area") { state.capture(.area) }
            .globalKeyboardShortcut(.captureArea)
        Button("Capture Window") { state.capture(.window) }
            .globalKeyboardShortcut(.captureWindow)
        Button("Capture Full Screen") { state.capture(.fullScreen) }
            .globalKeyboardShortcut(.captureFullScreen)
        Button("Capture Text") { state.captureText() }
            .globalKeyboardShortcut(.captureText)
        Divider()
        Button("Record Screen…") { state.recordScreen() }
            .globalKeyboardShortcut(.recordScreen)
        Button("Record Area") { state.record(.area) }
            .globalKeyboardShortcut(.recordArea)
        Button("Record Window") { state.record(.window) }
            .globalKeyboardShortcut(.recordWindow)
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
