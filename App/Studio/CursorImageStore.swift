import AppKit
import ImageIO
import UniformTypeIdentifiers

enum CursorImageError: Error, LocalizedError {
    case noImage
    case encodingFailed(URL)

    var errorDescription: String? {
        switch self {
        case .noImage: "The cursor has no image to record."
        case .encodingFailed(let url): "Could not write the cursor image to \(url.path)."
        }
    }
}

final class CursorImageStore {
    private let folder: URL
    private var written: Set<String> = []
    private(set) var pngWrites = 0

    init(folder: URL) {
        self.folder = folder
    }

    func name(for cursor: NSCursor) throws -> String {
        let image = cursor.image
        var proposed = CGRect(origin: .zero, size: image.size)
        guard image.size.width > 0, let flat = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else {
            throw CursorImageError.noImage
        }
        var hasher = Hasher()
        hasher.combine(flat.width)
        hasher.combine(flat.height)
        hasher.combine(flat.dataProvider?.data as Data?)
        hasher.combine(cursor.hotSpot.x)
        hasher.combine(cursor.hotSpot.y)
        let name = "\(String(UInt64(bitPattern: Int64(hasher.finalize())), radix: 16)).png"

        guard !written.contains(name) else { return name }
        let file = folder.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try writePNG(of: image, fallback: flat, to: file)
            pngWrites += 1
        }
        written.insert(name)
        return name
    }

    private func writePNG(of image: NSImage, fallback: CGImage, to file: URL) throws {
        let sharpest = image.representations
            .compactMap { $0 as? NSBitmapImageRep }
            .max { $0.pixelsWide < $1.pixelsWide }?
            .cgImage ?? fallback
        let dpi = 72 * Double(sharpest.width) / image.size.width
        guard let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CursorImageError.encodingFailed(file)
        }
        CGImageDestinationAddImage(destination, sharpest, [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CursorImageError.encodingFailed(file) }
    }
}
