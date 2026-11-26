import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import LunettaCore
import UniformTypeIdentifiers

public struct CompressionResult: Sendable, Equatable {
    public let originalBytes: Int
    public let compressedBytes: Int

    public init(originalBytes: Int, compressedBytes: Int) {
        self.originalBytes = originalBytes
        self.compressedBytes = compressedBytes
    }

    /// 0.62 when the file shrank to 38% of its size.
    public var savedFraction: Double {
        1 - Double(compressedBytes) / Double(originalBytes)
    }
}

/// Shrinks a saved capture in place. A screenshot becomes an indexed PNG of at most 256 colors; a recording is encoded
/// again in its own codec, without the real-time deadline it was recorded under. A copy no smaller than the original is
/// thrown away.
public enum CaptureCompressor {
    /// nil when the compressed copy came out no smaller, so the original stays.
    public static func compress(_ url: URL) async throws -> CompressionResult? {
        do {
            let files = FileManager.default
            let scratch = try files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
            defer { try? files.removeItem(at: scratch) }
            let compressed = scratch.appending(path: url.lastPathComponent)
            if UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true {
                try await reencode(url, to: compressed)
            } else {
                try palettedPNG(of: url).write(to: compressed)
            }
            let original = try size(of: url)
            let shrunk = try size(of: compressed)
            guard shrunk < original else { return nil }
            _ = try files.replaceItemAt(url, withItemAt: compressed)
            return CompressionResult(originalBytes: original, compressedBytes: shrunk)
        } catch let error as CaptureError {
            throw error
        } catch {
            throw CaptureError.compressionFailed(path: url.path, reason: error.localizedDescription)
        }
    }

    static func palettedPNG(of url: URL) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw CaptureError.compressionFailed(path: url.path, reason: "ImageIO couldn't read the screenshot") }
        let (space, profile) = colorSpace(of: image)
        guard let rgba = straightRGBA(of: image, in: space) else {
            throw CaptureError.compressionFailed(path: url.path, reason: "Core Graphics couldn't draw the \(image.width) × \(image.height) screenshot")
        }
        let paletted = PaletteQuantizer.quantize(rgba: rgba, width: image.width, height: image.height)
        return try IndexedPNG.encode(paletted, profile: profile) { try ($0 as NSData).compressed(using: .zlib) as Data }
    }

    /// The screenshot's own profile when it has one, so no pixel is converted; sRGB otherwise. A screenshot that is
    /// already indexed keeps the profile its palette is in.
    static func colorSpace(of image: CGImage) -> (CGColorSpace, IndexedPNG.ColorProfile) {
        let space = image.colorSpace?.model == .indexed ? image.colorSpace?.baseColorSpace : image.colorSpace
        if let space, space.model == .rgb, let icc = space.copyICCData() {
            return (space, .icc(name: "ICC Profile", data: icc as Data))
        }
        return (CGColorSpace(name: CGColorSpace.sRGB)!, .sRGB)
    }

    /// Core Graphics only draws premultiplied alpha; PNG stores it straight.
    static func straightRGBA(of image: CGImage, in space: CGColorSpace) -> [UInt8]? {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[offset + 3])
            guard alpha > 0, alpha < 255 else { continue }
            for channel in offset..<offset + 3 {
                pixels[channel] = UInt8(min(255, (Int(pixels[channel]) * 255 + alpha / 2) / alpha))
            }
        }
        return pixels
    }

    private static func reencode(_ url: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: url)
        let preset = try await exportPreset(for: asset)
        guard let export = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw CaptureError.compressionFailed(path: url.path, reason: "AVFoundation has no \(preset) export for this recording")
        }
        try await export.export(to: destination, as: .mp4)
    }

    /// Same codec out as in: an H.264 recording was picked because it plays everywhere, and HEVC doesn't.
    static func exportPreset(for asset: AVAsset) async throws -> String {
        for track in try await asset.loadTracks(withMediaType: .video) {
            let formats = try await track.load(.formatDescriptions)
            if formats.contains(where: { CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_HEVC }) {
                return AVAssetExportPresetHEVCHighestQuality
            }
        }
        return AVAssetExportPresetHighestQuality
    }

    private static func size(of url: URL) throws -> Int {
        try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    }
}
