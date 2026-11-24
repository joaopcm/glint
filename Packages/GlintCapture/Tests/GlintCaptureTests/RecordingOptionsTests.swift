import GlintCore
import ScreenCaptureKit
import Testing
@testable import GlintCapture

@Test(arguments: [(false, false), (true, false), (false, true), (true, true)])
func eachAudioToggleAddsOnlyItsOwnStream(systemAudio: Bool, microphone: Bool) {
    let configuration = SCStreamConfiguration()
    ScreenCapturer.apply(RecordingOptions(codec: .h264, systemAudio: systemAudio, microphone: microphone), to: configuration)
    #expect(configuration.capturesAudio == systemAudio)
    #expect(configuration.captureMicrophone == microphone)
    #expect(configuration.excludesCurrentProcessAudio)
    #expect(configuration.showsCursor)
}
