import Testing
@testable import LunettaCapture

@Test func permissionDeniedPointsToSystemSettings() {
    let message = CaptureError.permissionDenied.errorDescription ?? ""
    #expect(message.contains("Screen Recording"))
    #expect(message.contains("System Settings > Privacy & Security"))
    #expect(message.contains("quit and reopen Lunetta"))
}

@Test func notFoundErrorsNameTheID() {
    #expect(CaptureError.displayNotFound(69_733_382).errorDescription?.contains("69733382") == true)
    #expect(CaptureError.windowNotFound(4_242).errorDescription?.contains("4242") == true)
}

@Test func writeFailedNamesPathAndReason() {
    let message = CaptureError.writeFailed(path: "/tmp/shots/a.png", underlying: "Permission denied").errorDescription ?? ""
    #expect(message.contains("/tmp/shots/a.png"))
    #expect(message.contains("Permission denied"))
}

@Test func textRecognitionFailedNamesTheReason() {
    let message = CaptureError.textRecognitionFailed("The image is too small").errorDescription ?? ""
    #expect(message.contains("The image is too small"))
}
