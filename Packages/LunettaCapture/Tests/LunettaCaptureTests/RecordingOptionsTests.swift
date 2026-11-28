import CoreMedia
import LunettaCore
import ScreenCaptureKit
import Testing
@testable import LunettaCapture

@Test(arguments: [(false, false), (true, false), (false, true), (true, true)])
func eachAudioToggleAddsOnlyItsOwnStream(systemAudio: Bool, microphone: Bool) {
    let configuration = SCStreamConfiguration()
    ScreenCapturer.apply(RecordingOptions(codec: .h264, systemAudio: systemAudio, microphone: microphone), to: configuration)
    #expect(configuration.capturesAudio == systemAudio)
    #expect(configuration.captureMicrophone == microphone)
    #expect(configuration.excludesCurrentProcessAudio)
    #expect(configuration.showsCursor)
}

@Test func rawRecordingsLeaveTheCursorOut() {
    let configuration = SCStreamConfiguration()
    ScreenCapturer.apply(RecordingOptions(codec: .h264, systemAudio: false, microphone: false, capturesCursor: false), to: configuration)
    #expect(!configuration.showsCursor)
}

@Test func theChosenInputAndClickHighlightsReachTheStream() {
    let configuration = SCStreamConfiguration()
    ScreenCapturer.apply(RecordingOptions(codec: .h264, systemAudio: false, microphone: true, microphoneID: "usb-1", showsClicks: true), to: configuration)
    #expect(configuration.microphoneCaptureDeviceID == "usb-1")
    #expect(configuration.showMouseClicks)
}

@Test func noMicrophoneMeansNoInputAndClicksStayOffUnlessAsked() {
    let configuration = SCStreamConfiguration()
    ScreenCapturer.apply(RecordingOptions(codec: .h264, systemAudio: false, microphone: false, microphoneID: "usb-1"), to: configuration)
    #expect(configuration.microphoneCaptureDeviceID == nil)
    #expect(!configuration.showMouseClicks)
}

@Test(arguments: RecordingFrameRate.allCases)
func theChosenFrameRateCapsTheStream(frameRate: RecordingFrameRate) {
    let configuration = SCStreamConfiguration()
    ScreenCapturer.apply(RecordingOptions(codec: .h264, frameRate: frameRate, systemAudio: false, microphone: false), to: configuration)
    #expect(configuration.minimumFrameInterval == CMTime(value: 1, timescale: CMTimeScale(frameRate.rawValue)))
}
