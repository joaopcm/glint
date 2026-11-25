import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum PNGWriter {
    public static func write(_ image: CGImage, to url: URL) throws {
        let data = try encode(image, path: url.path)
        try write(data, to: url)
    }

    public static func write(_ data: Data, to url: URL) throws {
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw CaptureError.writeFailed(path: url.path, underlying: reason(error))
        }
    }

    public static func encode(_ image: CGImage, path: String = "") throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw CaptureError.writeFailed(path: path, underlying: "ImageIO could not create a PNG encoder")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CaptureError.writeFailed(path: path, underlying: "ImageIO could not encode the image as PNG")
        }
        return data as Data
    }

    private static func reason(_ error: Error) -> String {
        guard let posix = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError, posix.domain == NSPOSIXErrorDomain else {
            return error.localizedDescription
        }
        return String(cString: strerror(Int32(posix.code)))
    }
}
