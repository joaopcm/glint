import Foundation

public enum RecordingMode: String, CaseIterable, Sendable {
    case area, window
}

/// Whether macOS lets Lunetta use a microphone or a camera.
public enum DeviceAccess: Sendable {
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

/// A camera, as macOS lists it. `id` is the device's unique ID.
public struct CameraInput: Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// What the recording panel sets, and the record hotkeys reuse. `input` and `cameraInput` are nil for the system's
/// default device.
public struct RecordingChoices: Equatable, Sendable {
    public var systemAudio: Bool
    public var microphone: Bool
    public var input: AudioInput?
    public var camera: Bool
    public var cameraInput: CameraInput?
    public var showsKeys: Bool
    public var showsClicks: Bool

    public init(
        systemAudio: Bool,
        microphone: Bool,
        input: AudioInput?,
        camera: Bool = false,
        cameraInput: CameraInput? = nil,
        showsKeys: Bool,
        showsClicks: Bool
    ) {
        self.systemAudio = systemAudio
        self.microphone = microphone
        self.input = input
        self.camera = camera
        self.cameraInput = cameraInput
        self.showsKeys = showsKeys
        self.showsClicks = showsClicks
    }
}

public enum RecordingFix: String, Sendable {
    case allowMicrophone = "Allow Microphone"
    case openMicrophoneSettings = "Open Microphone Settings"
    case allowCamera = "Allow Camera"
    case openCameraSettings = "Open Camera Settings"
    case openInputMonitoringSettings = "Open Input Monitoring Settings"
}

/// Something that would make a recording silently miss what was asked for, so the recording doesn't start.
public enum RecordingProblem: Error, LocalizedError, Hashable, Sendable {
    case microphoneNotAllowedYet
    case microphoneDenied
    case inputMissing(AudioInput)
    case cameraNotAllowedYet
    case cameraDenied
    case cameraMissing(CameraInput)
    case noCamera
    case cameraNeedsArea
    case keysNeedArea
    case inputMonitoringDenied

    public var errorDescription: String? {
        switch self {
        case .microphoneNotAllowedYet:
            "Microphone is on, but macOS hasn't asked yet whether Lunetta may use the microphone. Click Allow Microphone and choose Allow, or turn off Microphone in the recording toolbar."
        case .microphoneDenied:
            "Microphone is on, but Lunetta isn't allowed to use the microphone. Turn on Lunetta in System Settings > Privacy & Security > Microphone, or turn off Microphone in the recording toolbar."
        case .inputMissing(let input):
            "The input \"\(input.name)\" isn't connected. Connect it, or pick another input in the recording toolbar."
        case .cameraNotAllowedYet:
            "Camera is on, but macOS hasn't asked yet whether Lunetta may use the camera. Click Allow Camera and choose Allow, or turn off Camera in the recording toolbar."
        case .cameraDenied:
            "Camera is on, but Lunetta isn't allowed to use the camera. Turn on Lunetta in System Settings > Privacy & Security > Camera, or turn off Camera in the recording toolbar."
        case .cameraMissing(let camera):
            "The camera \"\(camera.name)\" isn't connected. Connect it, or pick another camera in the recording toolbar."
        case .noCamera:
            "Camera is on, but no camera is connected. Connect one, or turn off Camera in the recording toolbar."
        case .cameraNeedsArea:
            "Camera only works in area recordings: a window recording captures that window alone, without the camera Lunetta shows over it. Record an area, or turn off Camera in the recording toolbar."
        case .keysNeedArea:
            "Show Pressed Keys only works in area recordings: a window recording captures that window alone, without the keys Lunetta draws over it. Record an area, or turn off Show Pressed Keys in the recording toolbar."
        case .inputMonitoringDenied:
            "Show Pressed Keys is on, but Lunetta isn't allowed to read the keyboard. Turn on Lunetta in System Settings > Privacy & Security > Input Monitoring and reopen Lunetta, or turn off Show Pressed Keys in the recording toolbar."
        }
    }

    public var fix: RecordingFix? {
        switch self {
        case .microphoneNotAllowedYet: .allowMicrophone
        case .microphoneDenied: .openMicrophoneSettings
        case .cameraNotAllowedYet: .allowCamera
        case .cameraDenied: .openCameraSettings
        case .inputMonitoringDenied: .openInputMonitoringSettings
        case .inputMissing, .cameraMissing, .noCamera, .cameraNeedsArea, .keysNeedArea: nil
        }
    }
}

public enum RecordingPreflight {
    /// Every problem at once, in panel order, so fixing one never uncovers another the user wasn't told about.
    public static func problems(
        mode: RecordingMode,
        choices: RecordingChoices,
        microphone: DeviceAccess,
        camera: DeviceAccess = .authorized,
        inputMonitoringAllowed: Bool,
        connectedInputs: [AudioInput],
        connectedCameras: [CameraInput] = []
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
        if choices.camera {
            switch camera {
            case .authorized: break
            case .notDetermined: problems.append(.cameraNotAllowedYet)
            case .denied: problems.append(.cameraDenied)
            }
            if let chosen = choices.cameraInput {
                if !connectedCameras.contains(where: { $0.id == chosen.id }) { problems.append(.cameraMissing(chosen)) }
            } else if connectedCameras.isEmpty {
                problems.append(.noCamera)
            }
            if mode == .window { problems.append(.cameraNeedsArea) }
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
