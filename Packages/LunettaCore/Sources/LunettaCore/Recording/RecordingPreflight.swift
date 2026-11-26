import Foundation

public enum RecordingMode: String, CaseIterable, Sendable {
    case area, window
}

public enum MicrophoneStatus: Sendable {
    case notDetermined, authorized, denied
}

/// A microphone or other audio input, as macOS lists it. `id` is the device's unique ID.
public struct AudioInput: Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// What the recording panel sets, and the record hotkeys reuse. `input` is nil for the system default input.
public struct RecordingChoices: Equatable, Sendable {
    public var systemAudio: Bool
    public var microphone: Bool
    public var input: AudioInput?
    public var showsKeys: Bool
    public var showsClicks: Bool

    public init(systemAudio: Bool, microphone: Bool, input: AudioInput?, showsKeys: Bool, showsClicks: Bool) {
        self.systemAudio = systemAudio
        self.microphone = microphone
        self.input = input
        self.showsKeys = showsKeys
        self.showsClicks = showsClicks
    }
}

public enum RecordingFix: String, Sendable {
    case allowMicrophone = "Allow Microphone"
    case openMicrophoneSettings = "Open Microphone Settings"
    case openInputMonitoringSettings = "Open Input Monitoring Settings"
}

/// Something that would make a recording silently miss what was asked for, so the recording doesn't start.
public enum RecordingProblem: Error, LocalizedError, Hashable, Sendable {
    case microphoneNotAllowedYet
    case microphoneDenied
    case inputMissing(AudioInput)
    case keysNeedArea
    case inputMonitoringDenied

    public var errorDescription: String? {
        switch self {
        case .microphoneNotAllowedYet:
            "Microphone is on, but macOS hasn't asked yet whether Lunetta may use the microphone. Click Allow Microphone and choose Allow, or turn off Microphone in the recording panel."
        case .microphoneDenied:
            "Microphone is on, but Lunetta isn't allowed to use the microphone. Turn on Lunetta in System Settings > Privacy & Security > Microphone, or turn off Microphone in the recording panel."
        case .inputMissing(let input):
            "The input \"\(input.name)\" isn't connected. Connect it, or pick another input in the recording panel."
        case .keysNeedArea:
            "Show Pressed Keys only works in area recordings: a window recording captures that window alone, without the keys Lunetta draws over it. Record an area, or turn off Show Pressed Keys in the recording panel."
        case .inputMonitoringDenied:
            "Show Pressed Keys is on, but Lunetta isn't allowed to read the keyboard. Turn on Lunetta in System Settings > Privacy & Security > Input Monitoring and reopen Lunetta, or turn off Show Pressed Keys in the recording panel."
        }
    }

    public var fix: RecordingFix? {
        switch self {
        case .microphoneNotAllowedYet: .allowMicrophone
        case .microphoneDenied: .openMicrophoneSettings
        case .inputMonitoringDenied: .openInputMonitoringSettings
        case .inputMissing, .keysNeedArea: nil
        }
    }
}

public enum RecordingPreflight {
    /// Every problem at once, in panel order, so fixing one never uncovers another the user wasn't told about.
    public static func problems(
        mode: RecordingMode,
        choices: RecordingChoices,
        microphone: MicrophoneStatus,
        inputMonitoringAllowed: Bool,
        connectedInputs: [AudioInput]
    ) -> [RecordingProblem] {
        var problems: [RecordingProblem] = []
        if choices.microphone {
            switch microphone {
            case .authorized: break
            case .notDetermined: problems.append(.microphoneNotAllowedYet)
            case .denied: problems.append(.microphoneDenied)
            }
            if let input = choices.input, !connectedInputs.contains(where: { $0.id == input.id }) {
                problems.append(.inputMissing(input))
            }
        }
        if choices.showsKeys {
            if mode == .window { problems.append(.keysNeedArea) }
            if !inputMonitoringAllowed { problems.append(.inputMonitoringDenied) }
        }
        return problems
    }
}

/// Why a recording ended early because its microphone went away, and whether anything was kept.
public enum InputDisconnected {
    public static func message(input: AudioInput, savedTo path: String?) -> String {
        let stopped = "The input \"\(input.name)\" was disconnected, so Lunetta stopped the recording instead of going on without its sound."
        guard let path else { return stopped }
        return "\(stopped) What was recorded until then is saved to \(path)."
    }
}
