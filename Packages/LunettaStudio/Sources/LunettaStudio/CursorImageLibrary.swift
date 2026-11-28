import CoreImage
import Foundation
import ImageIO
import Synchronization

/// Cursor images from a project's `cursors/` folder, sized in points: a PNG's DPI over 72 is its scale.
public final class CursorImageLibrary: Sendable {
    private static let pointsDPI = 72.0

    private let folder: URL
    private let loaded = Mutex<[String: CIImage?]>([:])

    public init(folder: URL) {
        self.folder = folder
    }

    public func image(named name: String) -> CIImage? {
        if let cached = loaded.withLock({ $0[name] }) { return cached }
        let image = Self.load(folder.appendingPathComponent(name))
        loaded.withLock { $0[name] = image }
        return image
    }

    private static func load(_ file: URL) -> CIImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let dpi = (properties?[kCGImagePropertyDPIWidth] as? Double) ?? pointsDPI
        let pointsPerPixel = pointsDPI / dpi
        return CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: pointsPerPixel, y: pointsPerPixel))
    }
}
