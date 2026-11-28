import CoreGraphics
import CoreVideo
import Foundation

public struct Frame: Sendable {
    public let width: Int, height: Int, bytesPerRow: Int
    public let pixels: [UInt8]
    public let colorSpace: CGColorSpace

    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    private static let fnvOffsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325
    private static let fnvPrime: UInt64 = 0x0000_0100_0000_01b3

    init(width: Int, height: Int, bytesPerRow: Int, pixels: [UInt8], colorSpace: CGColorSpace = Frame.sRGB) {
        precondition(pixels.count == bytesPerRow * height, "Frame \(width)x\(height) needs \(bytesPerRow * height) bytes, got \(pixels.count)")
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.pixels = pixels
        self.colorSpace = colorSpace
    }

    public init?(_ image: CGImage) {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: Self.sRGB,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return false }
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return nil }
        self.init(width: width, height: height, bytesPerRow: width * 4, pixels: pixels)
    }

    public init?(_ pixelBuffer: CVPixelBuffer) {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let sourceStride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let rowBytes = width * 4
        let pixels = [UInt8](unsafeUninitializedCapacity: rowBytes * height) { buffer, count in
            for y in 0..<height {
                memcpy(buffer.baseAddress! + y * rowBytes, base + y * sourceStride, rowBytes)
            }
            count = rowBytes * height
        }
        self.init(width: width, height: height, bytesPerRow: rowBytes, pixels: pixels, colorSpace: Self.colorSpace(of: pixelBuffer))
    }

    private static func colorSpace(of pixelBuffer: CVPixelBuffer) -> CGColorSpace {
        if let attached = CVImageBufferGetColorSpace(pixelBuffer) { return attached.takeUnretainedValue() }
        if let attachment = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferCGColorSpaceKey, nil), CFGetTypeID(attachment) == CGColorSpace.typeID {
            return attachment as! CGColorSpace
        }
        return sRGB
    }

    func rowSignatures(columns: Range<Int>, stride: Int) -> [UInt64] {
        precondition(stride > 0 && columns.lowerBound >= 0 && columns.upperBound <= width, "columns \(columns) stride \(stride) outside width \(width)")
        let sampledColumns = Self.samples(in: columns, stride: stride)
        return pixels.withUnsafeBufferPointer { bytes in
            (0..<height).map { y in
                var hash = Self.fnvOffsetBasis
                for x in sampledColumns {
                    hash = Self.mix(hash, bytes, at: y * bytesPerRow + x * 4)
                }
                return hash
            }
        }
    }

    func columnSignatures(stride: Int) -> [UInt64] {
        precondition(stride > 0, "stride \(stride) must be positive")
        let sampledRows = Self.samples(in: 0..<height, stride: stride)
        return pixels.withUnsafeBufferPointer { bytes in
            var hashes = [UInt64](repeating: Self.fnvOffsetBasis, count: width)
            for y in sampledRows {
                for x in 0..<width {
                    hashes[x] = Self.mix(hashes[x], bytes, at: y * bytesPerRow + x * 4)
                }
            }
            return hashes
        }
    }

    func isUniformRow(_ y: Int, columns: Range<Int>) -> Bool {
        guard let first = columns.first else { return true }
        let reference = y * bytesPerRow + first * 4
        return columns.allSatisfy { isSamePixel(y * bytesPerRow + $0 * 4, reference) }
    }

    func isUniformColumn(_ x: Int) -> Bool {
        (0..<height).dropFirst().allSatisfy { isSamePixel($0 * bytesPerRow + x * 4, x * 4) }
    }

    func cropped(columns: Range<Int>, rows: Range<Int>) -> Frame {
        precondition(
            columns.lowerBound >= 0 && columns.upperBound <= width && rows.lowerBound >= 0 && rows.upperBound <= height,
            "crop columns \(columns) rows \(rows) outside \(width)x\(height)"
        )
        let rowBytes = columns.count * 4
        var cropped = [UInt8]()
        cropped.reserveCapacity(rowBytes * rows.count)
        for y in rows {
            let start = y * bytesPerRow + columns.lowerBound * 4
            cropped.append(contentsOf: pixels[start..<(start + rowBytes)])
        }
        return Frame(width: columns.count, height: rows.count, bytesPerRow: rowBytes, pixels: cropped, colorSpace: colorSpace)
    }

    private func isSamePixel(_ a: Int, _ b: Int) -> Bool {
        pixels[a] == pixels[b] && pixels[a + 1] == pixels[b + 1] && pixels[a + 2] == pixels[b + 2] && pixels[a + 3] == pixels[b + 3]
    }

    private static func samples(in range: Range<Int>, stride: Int) -> [Int] {
        guard let last = range.last else { return [] }
        var indices = Array(Swift.stride(from: range.lowerBound, to: range.upperBound, by: stride))
        if indices.last != last { indices.append(last) }
        return indices
    }

    private static func mix(_ hash: UInt64, _ bytes: UnsafeBufferPointer<UInt8>, at offset: Int) -> UInt64 {
        var hash = hash
        for i in 0..<4 {
            hash = (hash ^ UInt64(bytes[offset + i])) &* fnvPrime
        }
        return hash
    }
}
