import Foundation

/// Writes a `PalettedImage` as an indexed-color PNG (PNG spec, 3rd edition: https://www.w3.org/TR/png-3/).
/// ImageIO only writes a palette for images without alpha, and window captures keep their shadow on transparency.
public enum IndexedPNG {
    public enum ColorProfile: Sendable, Equatable {
        case sRGB
        /// The capture's own ICC profile, so its colors look the same as in the original PNG.
        case icc(name: String, data: Data)
    }

    /// `deflate` turns bytes into a raw DEFLATE stream (RFC 1951); the zlib wrapper around it (RFC 1950) is added here.
    public static func encode(_ image: PalettedImage, profile: ColorProfile, deflate: (Data) throws -> Data) rethrows -> Data {
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let depth = bitDepth(forColors: image.palette.count)
        var header = Data()
        header.appendBigEndian(UInt32(image.width))
        header.appendBigEndian(UInt32(image.height))
        header.append(contentsOf: [depth, 3, 0, 0, 0]) // color type 3 = indexed; deflate, adaptive filtering, no interlace
        appendChunk("IHDR", header, to: &png)
        switch profile {
        case .sRGB:
            appendChunk("sRGB", Data([0]), to: &png) // rendering intent 0 = perceptual
        case .icc(let name, let data):
            var chunk = Data(name.utf8.prefix(79))
            chunk.append(contentsOf: [0, 0]) // name terminator, compression method 0 = zlib
            chunk.append(try zlib(data, deflate: deflate))
            appendChunk("iCCP", chunk, to: &png)
        }
        appendChunk("PLTE", Data(image.palette.flatMap { [PaletteQuantizer.channel(0, of: $0), PaletteQuantizer.channel(1, of: $0), PaletteQuantizer.channel(2, of: $0)] }), to: &png)
        let alphas = image.palette.map { PaletteQuantizer.channel(3, of: $0) }
        if let lastTranslucent = alphas.lastIndex(where: { $0 < 255 }) {
            appendChunk("tRNS", Data(alphas[...lastTranslucent]), to: &png)
        }
        appendChunk("IDAT", try zlib(scanlines(image, bitDepth: depth), deflate: deflate), to: &png)
        appendChunk("IEND", Data(), to: &png)
        return png
    }

    /// The fewest bits per pixel that still address every palette entry: 1, 2, 4 or 8.
    static func bitDepth(forColors count: Int) -> UInt8 {
        switch count {
        case ...2: 1
        case ...4: 2
        case ...16: 4
        default: 8
        }
    }

    /// Each row starts with filter type 0 (none), which the spec recommends for indexed images (12.7), then its
    /// indices packed most significant bit first.
    static func scanlines(_ image: PalettedImage, bitDepth: UInt8) -> Data {
        let depth = Int(bitDepth)
        let perByte = 8 / depth
        let rowBytes = (image.width + perByte - 1) / perByte
        var data = Data(count: image.height * (rowBytes + 1))
        data.withUnsafeMutableBytes { out in
            for row in 0..<image.height {
                let start = row * (rowBytes + 1) + 1
                for column in 0..<image.width {
                    let index = image.indices[row * image.width + column]
                    let shift = 8 - depth * (column % perByte + 1)
                    out[start + column / perByte] |= index << shift
                }
            }
        }
        return data
    }

    static func zlib(_ data: Data, deflate: (Data) throws -> Data) rethrows -> Data {
        var stream = Data([0x78, 0x9C]) // 32 KB window, default level; 0x789C is a multiple of 31 as RFC 1950 requires
        stream.append(try deflate(data))
        stream.appendBigEndian(adler32(data))
        return stream
    }

    private static func appendChunk(_ type: String, _ body: Data, to png: inout Data) {
        let typeAndBody = Data(type.utf8) + body
        png.appendBigEndian(UInt32(body.count))
        png.append(typeAndBody)
        png.appendBigEndian(crc32(typeAndBody))
    }

    private static let crcTable: [UInt32] = (0..<256).map { byte in
        (0..<8).reduce(UInt32(byte)) { crc, _ in crc & 1 == 1 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1 }
    }

    static func crc32(_ data: Data) -> UInt32 {
        ~data.reduce(~UInt32(0)) { crc, byte in crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
    }

    static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        // 5552 bytes is the most that can be summed before b overflows 32 bits (zlib's NMAX).
        for start in stride(from: data.startIndex, to: data.endIndex, by: 5552) {
            for byte in data[start..<min(start + 5552, data.endIndex)] {
                a += UInt32(byte)
                b += a
            }
            a %= 65521
            b %= 65521
        }
        return b << 16 | a
    }
}

private extension Data {
    mutating func appendBigEndian(_ value: UInt32) {
        append(contentsOf: [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }
}
