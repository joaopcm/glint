import CoreGraphics
import Vision

public enum TextRecognizer {
    public static func lines(in image: CGImage) async throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = true
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
        } catch {
            throw CaptureError.textRecognitionFailed(error.localizedDescription)
        }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }
}
