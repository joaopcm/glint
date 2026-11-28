import Foundation
import Testing
@testable import LunettaCore

private let deskMic = AudioInput(id: "usb-1", name: "Desk Mic")
private let builtIn = AudioInput(id: "built-in", name: "MacBook Pro Microphone")
private let faceTime = CameraInput(id: "facetime", name: "FaceTime HD Camera")
private let deskCam = CameraInput(id: "usb-cam", name: "Desk Cam")

private func choices(
    systemAudio: Bool = false,
    microphone: Bool = false,
    input: AudioInput? = nil,
    camera: Bool = false,
    cameraInput: CameraInput? = nil,
    showsKeys: Bool = false,
    showsClicks: Bool = false
) -> RecordingChoices {
    RecordingChoices(
        systemAudio: systemAudio, microphone: microphone, input: input, camera: camera, cameraInput: cameraInput,
        showsKeys: showsKeys, showsClicks: showsClicks
    )
}

private func problems(
    _ choices: RecordingChoices,
    microphone: DeviceAccess = .authorized,
    camera: DeviceAccess = .authorized,
    inputMonitoring: Bool = true,
    inputs: [AudioInput] = [builtIn, deskMic],
    cameras: [CameraInput] = [faceTime, deskCam]
) -> [RecordingProblem] {
    RecordingPreflight.problems(
        choices: choices, microphone: microphone, camera: camera, inputMonitoringAllowed: inputMonitoring,
        connectedInputs: inputs, connectedCameras: cameras
    )
}

@Test func systemAudioAndClicksNeedNothingBeyondScreenRecording() {
    #expect(problems(
        choices(systemAudio: true, showsClicks: true), microphone: .denied, camera: .denied, inputMonitoring: false, inputs: [], cameras: []
    ).isEmpty)
}

@Test func everythingGrantedAndConnectedHasNoProblem() {
    let all = choices(systemAudio: true, microphone: true, input: deskMic, camera: true, cameraInput: deskCam, showsKeys: true, showsClicks: true)
    #expect(problems(all).isEmpty)
}

@Test(arguments: [(DeviceAccess.notDetermined, RecordingProblem.microphoneNotAllowedYet), (.denied, .microphoneDenied)])
func theMicrophoneNeedsMicrophoneAccess(status: DeviceAccess, problem: RecordingProblem) {
    #expect(problems(choices(microphone: true), microphone: status) == [problem])
    #expect(problems(choices(microphone: false), microphone: status).isEmpty)
}

@Test func aChosenInputThatIsNotConnectedIsNamed() {
    #expect(problems(choices(microphone: true, input: deskMic), inputs: [builtIn]) == [.inputMissing(deskMic)])
    #expect(problems(choices(microphone: true), inputs: []).isEmpty, "the system default input is never missing")
    #expect(problems(choices(microphone: false, input: deskMic), inputs: []).isEmpty, "an input nobody records from doesn't matter")
}

@Test(arguments: [(DeviceAccess.notDetermined, RecordingProblem.cameraNotAllowedYet), (.denied, .cameraDenied)])
func theCameraNeedsCameraAccess(status: DeviceAccess, problem: RecordingProblem) {
    #expect(problems(choices(camera: true), camera: status) == [problem])
    #expect(problems(choices(camera: false), camera: status).isEmpty)
}

@Test func aChosenCameraThatIsNotConnectedIsNamed() {
    #expect(problems(choices(camera: true, cameraInput: deskCam), cameras: [faceTime]) == [.cameraMissing(deskCam)])
    #expect(problems(choices(camera: false, cameraInput: deskCam), cameras: []).isEmpty, "a camera nobody shows doesn't matter")
}

@Test func theSystemCameraNeedsSomeCameraConnected() {
    #expect(problems(choices(camera: true), cameras: []) == [.noCamera])
    #expect(problems(choices(camera: true), cameras: [deskCam]).isEmpty)
}

@Test func pressedKeysNeedInputMonitoring() {
    #expect(problems(choices(showsKeys: true), inputMonitoring: false) == [.inputMonitoringDenied])
    #expect(problems(choices(showsKeys: false), inputMonitoring: false).isEmpty)
}

@Test func everyProblemIsListedInPanelOrder() {
    let all = choices(microphone: true, input: deskMic, camera: true, cameraInput: deskCam, showsKeys: true)
    #expect(problems(all, microphone: .denied, camera: .notDetermined, inputMonitoring: false, inputs: [], cameras: []) == [
        .microphoneDenied, .inputMissing(deskMic), .cameraNotAllowedYet, .cameraMissing(deskCam), .inputMonitoringDenied,
    ])
}

@Test(arguments: [
    (RecordingProblem.microphoneNotAllowedYet, "Allow Microphone", RecordingFix?.some(.allowMicrophone)),
    (.microphoneDenied, "System Settings > Privacy & Security > Microphone", .openMicrophoneSettings),
    (.inputMissing(deskMic), "\"Desk Mic\" isn't connected", nil),
    (.cameraNotAllowedYet, "Allow Camera", .allowCamera),
    (.cameraDenied, "System Settings > Privacy & Security > Camera", .openCameraSettings),
    (.cameraMissing(deskCam), "\"Desk Cam\" isn't connected", nil),
    (.noCamera, "no camera is connected", nil),
    (.inputMonitoringDenied, "System Settings > Privacy & Security > Input Monitoring", .openInputMonitoringSettings),
])
func everyProblemSaysWhatFailedAndHowToFixIt(problem: RecordingProblem, how: String, fix: RecordingFix?) throws {
    let message = try #require(problem.errorDescription)
    #expect(message.contains(how))
    #expect(problem.fix == fix)
    #expect(problem.localizedDescription == message)
}

@Test func aLostInputIsNamedAndSaysWhereTheRecordingWent() {
    let saved = InputDisconnected.message(input: deskMic, savedTo: "/Users/me/Desktop/Lunetta.mp4")
    #expect(saved.contains("\"Desk Mic\" was disconnected"))
    #expect(saved.contains("saved to /Users/me/Desktop/Lunetta.mp4"))
    #expect(!InputDisconnected.message(input: deskMic, savedTo: nil).contains("saved"))
}
