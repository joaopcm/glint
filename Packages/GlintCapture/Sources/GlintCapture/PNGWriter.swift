import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum PNGWriter {
    public static func write(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CaptureError.writeFailed(path: url.path, underlying: reason(writing: url))
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CaptureError.writeFailed(path: url.path, underlying: reason(writing: url))
        }
    }

    private static func reason(writing url: URL) -> String {
        let folder = url.deletingLastPathComponent().path
        guard access(folder, W_OK) == 0 else { return "\(folder): \(String(cString: strerror(errno)))" }
        return "ImageIO could not encode or write the PNG"
    }
}
