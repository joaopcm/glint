import CoreGraphics
import LunettaCapture
import Testing
@testable import Lunetta

@MainActor
private final class Spy: AlertPresenting {
    var copied: [String] = []
    var outcomes: [TextCaptureOutcome] = []
    var alerts: [CaptureAlert] = []

    func present(_ alert: CaptureAlert) -> CaptureAlert.Button {
        alerts.append(alert)
        return .ok
    }
}

private func whiteImage() -> CGImage {
    let context = CGContext(
        data: nil, width: 640, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 640, height: 200))
    return context.makeImage()!
}

@MainActor
private func makeCapture(
    _ spy: Spy,
    image: CGImage? = whiteImage(),
    recognize: @escaping @Sendable (CGImage) async throws -> [String] = TextRecognizer.lines(in:)
) -> TextCapture {
    TextCapture(
        captureImage: { image },
        recognize: recognize,
        copyText: { spy.copied.append($0) },
        alerts: spy,
        onOutcome: { spy.outcomes.append($0) }
    )
}

@MainActor @Test func emptyImageSaysNoTextFoundAndLeavesTheClipboardAlone() async {
    let spy = Spy()
    let outcome = await makeCapture(spy).run()
    #expect(outcome == .noText)
    #expect(spy.outcomes == [.noText])
    #expect(spy.copied.isEmpty)
    #expect(spy.alerts.isEmpty)
    #expect(TextCaptureOutcome.noText.message == "No text found")
}

@MainActor @Test func linesAreJoinedWithNewlinesAndCounted() async {
    let spy = Spy()
    let outcome = await makeCapture(spy, recognize: { _ in ["one", "two", "three"] }).run()
    #expect(outcome == .copied(lineCount: 3))
    #expect(spy.copied == ["one\ntwo\nthree"])
    #expect(outcome?.message == "Copied 3 lines")
    #expect(TextCaptureOutcome.copied(lineCount: 1).message == "Copied 1 line")
}

@MainActor @Test func cancelledSelectionDoesNothing() async {
    let spy = Spy()
    let outcome = await makeCapture(spy, image: nil, recognize: { _ in ["unused"] }).run()
    #expect(outcome == nil)
    #expect(spy.outcomes.isEmpty)
    #expect(spy.copied.isEmpty)
    #expect(spy.alerts.isEmpty)
}

@MainActor @Test func recognitionFailureShowsTheReason() async {
    let spy = Spy()
    let outcome = await makeCapture(spy, recognize: { _ in throw CaptureError.textRecognitionFailed("The image is too small") }).run()
    #expect(outcome == nil)
    #expect(spy.copied.isEmpty)
    #expect(spy.outcomes.isEmpty)
    #expect(spy.alerts.map(\.message) == ["Could not read the text in the selection: The image is too small"])
}

@MainActor @Test func toastShowsTheMessageThenHides() async throws {
    let toast = ToastPresenter(visibleFor: .milliseconds(300), pointerLocation: { offScreen })
    toast.show("Copied 3 lines")
    #expect(toast.visibleMessage == "Copied 3 lines")
    try await Task.sleep(for: .seconds(1))
    #expect(toast.visibleMessage == nil)
}

@MainActor @Test func toastShownUntilHiddenStaysUpAndHidesOnlyItsOwnMessage() async throws {
    let toast = ToastPresenter(visibleFor: .milliseconds(300), pointerLocation: { offScreen })
    toast.showUntilHidden("Click Allow")
    try await Task.sleep(for: .seconds(1))
    #expect(toast.visibleMessage == "Click Allow")

    toast.show("Copied 3 lines")
    toast.hide("Click Allow")
    #expect(toast.visibleMessage == "Copied 3 lines")

    toast.showUntilHidden("Click Allow")
    toast.hide("Click Allow")
    #expect(toast.visibleMessage == nil)
}
