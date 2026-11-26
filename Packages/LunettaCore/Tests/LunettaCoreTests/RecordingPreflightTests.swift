import Foundation
import Testing
@testable import LunettaCore

private let deskMic = AudioInput(id: "usb-1", name: "Desk Mic")
private let builtIn = AudioInput(id: "built-in", name: "MacBook Pro Microphone")

private func choices(
    systemAudio: Bool = false,
    microphone: Bool = false,
    input: AudioInput? = nil,
    showsKeys: Bool = false,
    showsClicks: Bool = false
) -> RecordingChoices {
    RecordingChoices(systemAudio: systemAudio, microphone: microphone, input: input, showsKeys: showsKeys, showsClicks: showsClicks)
}

private func problems(
    _ choices: RecordingChoices,
    mode: RecordingMode = .area,
    microphone: MicrophoneStatus = .authorized,
    inputMonitoring: Bool = true,
    inputs: [AudioInput] = [builtIn, deskMic]
) -> [RecordingProblem] {
    RecordingPreflight.problems(mode: mode, choices: choices, microphone: microphone, inputMonitoringAllowed: inputMonitoring, connectedInputs: inputs)
}

@Test(arguments: RecordingMode.allCases)
func systemAudioAndClicksNeedNothingBeyondScreenRecording(mode: RecordingMode) {
    #expect(problems(choices(systemAudio: true, showsClicks: true), mode: mode, microphone: .denied, inputMonitoring: false, inputs: []).isEmpty)
}

@Test func everythingGrantedAndConnectedHasNoProblem() {
    let all = choices(systemAudio: true, microphone: true, input: deskMic, showsKeys: true, showsClicks: true)
    #expect(problems(all).isEmpty)
}

@Test(arguments: [(MicrophoneStatus.notDetermined, RecordingProblem.microphoneNotAllowedYet), (.denied, .microphoneDenied)])
func theMicrophoneNeedsMicrophoneAccess(status: MicrophoneStatus, problem: RecordingProblem) {
    #expect(problems(choices(microphone: true), microphone: status) == [problem])
    #expect(problems(choices(microphone: false), microphone: status).isEmpty)
}

@Test func aChosenInputThatIsNotConnectedIsNamed() {
    #expect(problems(choices(microphone: true, input: deskMic), inputs: [builtIn]) == [.inputMissing(deskMic)])
    #expect(problems(choices(microphone: true), inputs: []).isEmpty, "the system default input is never missing")
    #expect(problems(choices(microphone: false, input: deskMic), inputs: []).isEmpty, "an input nobody records from doesn't matter")
}

@Test func pressedKeysNeedInputMonitoringAndAnArea() {
    #expect(problems(choices(showsKeys: true), inputMonitoring: false) == [.inputMonitoringDenied])
    #expect(problems(choices(showsKeys: true), mode: .window) == [.keysNeedArea])
    #expect(problems(choices(showsKeys: false), mode: .window, inputMonitoring: false).isEmpty)
}

@Test func everyProblemIsListedInPanelOrder() {
    let all = choices(microphone: true, input: deskMic, showsKeys: true)
    #expect(problems(all, mode: .window, microphone: .denied, inputMonitoring: false, inputs: []) == [
        .microphoneDenied, .inputMissing(deskMic), .keysNeedArea, .inputMonitoringDenied,
    ])
}

@Test(arguments: [
    (RecordingProblem.microphoneNotAllowedYet, "Allow Microphone", RecordingFix?.some(.allowMicrophone)),
    (.microphoneDenied, "System Settings > Privacy & Security > Microphone", .openMicrophoneSettings),
    (.inputMissing(deskMic), "\"Desk Mic\" isn't connected", nil),
    (.keysNeedArea, "Record an area", nil),
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
