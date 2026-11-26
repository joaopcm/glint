import AppKit
import LunettaCore
import SwiftUI

struct SoundsSettingsView: View {
    @Bindable var settings: LunettaSettings
    @State private var player = SoundPreviewPlayer()

    var body: some View {
        Form {
            Section("Screenshots") {
                Toggle("Play sound on capture", isOn: $settings.playSoundOnCapture)
                row("Shutter", id: "shutter", url: ShutterSound.systemFile)
            }
            Section {
                Toggle("Play recording sounds", isOn: $settings.recordingSounds)
                ForEach(RecordingSounds.Cue.allCases, id: \.self) { cue in
                    row(cue.title, id: cue.rawValue, url: Bundle.main.url(forResource: cue.rawValue, withExtension: "wav"))
                }
            } header: {
                Text("Recordings")
            } footer: {
                if !SoundPreviewPlayer.systemPlaysInterfaceSounds {
                    Text("macOS has \"Play user interface sound effects\" off in System Settings > Sound, so recordings stay silent.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let failure = player.failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsLayout.width)
    }

    private func row(_ title: String, id: String, url: URL?) -> some View {
        LabeledContent(title) {
            Button {
                player.play(url, named: title)
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.borderless)
            .help("Play \(title)")
            .accessibilityLabel("Play \(title)")
            .accessibilityIdentifier(AccessibilityID.soundPreview(id))
        }
    }
}

extension RecordingSounds.Cue {
    var title: String {
        switch self {
        case .tick: "Countdown tick"
        case .start: "Start"
        case .stop: "Stop"
        case .pause: "Pause"
        case .resume: "Resume"
        case .discard: "Discard"
        }
    }
}

/// Plays a sound on request even with its setting off, so it can be heard before turning it on.
@MainActor @Observable
private final class SoundPreviewPlayer {
    private(set) var failure: String?
    @ObservationIgnored private var playing: NSSound?

    static var systemPlaysInterfaceSounds: Bool {
        UserDefaults.standard.object(forKey: "com.apple.sound.uiaudio.enabled") as? Bool ?? true
    }

    func play(_ url: URL?, named title: String) {
        playing?.stop()
        guard let url else {
            failure = "Can't play \(title): its sound is missing from the app bundle."
            return
        }
        guard let sound = NSSound(contentsOf: url, byReference: true) else {
            failure = "Can't play \(title): macOS can't read \(url.path)."
            return
        }
        failure = nil
        playing = sound
        sound.play()
    }
}
