import AppKit
import GlintCapture

enum TextCaptureOutcome: Equatable {
    case copied(lineCount: Int)
    case noText

    var message: String {
        switch self {
        case .copied(1): "Copied 1 line"
        case .copied(let count): "Copied \(count) lines"
        case .noText: "No text found"
        }
    }
}

@MainActor
final class TextCapture {
    private let captureImage: @MainActor () async -> CGImage?
    private let recognize: @Sendable (CGImage) async throws -> [String]
    private let copyText: @MainActor (String) throws -> Void
    private let alerts: any AlertPresenting
    private let onOutcome: @MainActor (TextCaptureOutcome) -> Void

    init(
        captureImage: @escaping @MainActor () async -> CGImage?,
        recognize: @escaping @Sendable (CGImage) async throws -> [String] = TextRecognizer.lines(in:),
        copyText: @escaping @MainActor (String) throws -> Void = { try NSPasteboard.general.copyText($0) },
        alerts: any AlertPresenting,
        onOutcome: @escaping @MainActor (TextCaptureOutcome) -> Void
    ) {
        self.captureImage = captureImage
        self.recognize = recognize
        self.copyText = copyText
        self.alerts = alerts
        self.onOutcome = onOutcome
    }

    @discardableResult
    func run() async -> TextCaptureOutcome? {
        guard let image = await captureImage() else { return nil }
        do {
            let lines = try await recognize(image)
            if !lines.isEmpty {
                try copyText(lines.joined(separator: "\n"))
            }
            let outcome: TextCaptureOutcome = lines.isEmpty ? .noText : .copied(lineCount: lines.count)
            onOutcome(outcome)
            return outcome
        } catch {
            _ = alerts.present(CaptureAlert(title: "Glint couldn't copy the text", message: error.localizedDescription, buttons: [.ok]))
            return nil
        }
    }
}
