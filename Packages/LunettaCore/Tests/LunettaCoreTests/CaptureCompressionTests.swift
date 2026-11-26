import Foundation
import Testing
@testable import LunettaCore

private func rgba(_ pixels: [UInt32]) -> [UInt8] {
    pixels.flatMap { [UInt8($0 >> 24), UInt8($0 >> 16 & 0xFF), UInt8($0 >> 8 & 0xFF), UInt8($0 & 0xFF)] }
}

private func colors(of image: PalettedImage) -> [UInt32] {
    image.indices.map { image.palette[Int($0)] }
}

private func channelError(_ a: UInt32, _ b: UInt32) -> Int {
    (0..<4).map { abs(Int(PaletteQuantizer.channel($0, of: a)) - Int(PaletteQuantizer.channel($0, of: b))) }.max()!
}

@Test func aCaptureOfFewColorsKeepsEveryPixelExactly() {
    let pixels: [UInt32] = [0xFFFF_FFFF, 0xFFFF_FFFF, 0x1E1E_1EFF, 0x0A84_FFFF, 0x0000_0080, 0xFFFF_FFFF]
    let image = PaletteQuantizer.quantize(rgba: rgba(pixels), width: 3, height: 2)
    #expect(image.palette.count == 4)
    #expect(colors(of: image) == pixels)
}

@Test func fullyTransparentPixelsShareOneEntry() {
    let pixels: [UInt32] = [0xFF00_0000, 0x00FF_0000, 0x0000_FF00, 0xFFFF_FFFF]
    let image = PaletteQuantizer.quantize(rgba: rgba(pixels), width: 4, height: 1)
    #expect(image.palette.count == 2)
    #expect(colors(of: image) == [0, 0, 0, 0xFFFF_FFFF])
}

/// A white page with a 64 × 64 two-axis gradient in it: 4097 colors for 256 entries.
@Test func aCaptureOfManyColorsFitsThePaletteAndStaysClose() {
    let side = 64
    var pixels = [UInt32](repeating: 0xFFFF_FFFF, count: side * side * 4)
    for y in 0..<side {
        for x in 0..<side {
            pixels[y * side * 2 + x] = UInt32(x * 4) << 24 | UInt32(y * 4) << 16 | 0x80 << 8 | 0xFF
        }
    }
    let image = PaletteQuantizer.quantize(rgba: rgba(pixels), width: side * 2, height: side * 2)
    #expect(image.palette.count == PaletteQuantizer.maxColors)
    let quantized = colors(of: image)
    #expect(zip(pixels, quantized).allSatisfy { $0 != 0xFFFF_FFFF || $1 == 0xFFFF_FFFF }) // the page stays exactly white
    // The white takes one entry, leaving 255 for 256 patches of 4 × 4 colors in 4-level steps. A 4 × 4 patch is 6 levels
    // from its middle at most; the one patch left over doubles to 4 × 8, 14 levels from its middle.
    let errors = zip(pixels, quantized).map { channelError($0, $1) }
    #expect(errors.max()! <= 14)
    #expect(Double(errors.reduce(0, +)) / Double(side * side) <= 6) // measured 5.07
}

@Test func indexedPNGPicksTheFewestBitsThatHoldThePalette() {
    #expect([1, 2, 3, 4, 5, 16, 17, 256].map(IndexedPNG.bitDepth(forColors:)) == [1, 1, 2, 2, 4, 4, 8, 8])
}

@Test func checksumsMatchTheirReferenceValues() {
    #expect(IndexedPNG.crc32(Data("IEND".utf8)) == 0xAE42_6082) // every PNG's IEND chunk ends in these bytes
    #expect(IndexedPNG.adler32(Data("Wikipedia".utf8)) == 0x11E6_0398) // the worked example on Wikipedia's Adler-32 page
    #expect(IndexedPNG.adler32(Data(repeating: 0xFF, count: 100_000)) == 0x149A_302C) // python3 -c 'import zlib; print(hex(zlib.adler32(b"\xff"*100000)))'
}

@Test(arguments: [2, 3, 9, 200])
func indexedPNGRoundTripsThroughItsChunks(paletteSize: Int) throws {
    let width = 13 // not a multiple of 8, so packed rows end part way through a byte
    let height = 5
    let palette = (0..<paletteSize).map { UInt32($0) << 24 | 0x0020_4000 | UInt32($0 == 1 ? 0x80 : 0xFF) }
    let indices = (0..<width * height).map { UInt8($0 * 7 % paletteSize) }
    let image = PalettedImage(width: width, height: height, palette: palette, indices: indices)

    let decoded = try DecodedPNG(IndexedPNG.encode(image, profile: .sRGB, deflate: storedDeflate))

    #expect(decoded.chunkTypes == ["IHDR", "sRGB", "PLTE", "tRNS", "IDAT", "IEND"])
    #expect(decoded.width == width && decoded.height == height && decoded.colorType == 3)
    #expect(decoded.palette == palette.map { $0 & 0xFFFF_FF00 })
    #expect(decoded.transparency == [255, 0x80])
    #expect(decoded.indices == indices)
}

@Test func indexedPNGCarriesTheCapturesOwnColorProfile() throws {
    let image = PalettedImage(width: 1, height: 1, palette: [0xFFFF_FFFF], indices: [0])
    let profile = Data("not a real ICC profile, only bytes to carry".utf8)

    let decoded = try DecodedPNG(IndexedPNG.encode(image, profile: .icc(name: "Display P3", data: profile), deflate: storedDeflate))

    #expect(decoded.chunkTypes == ["IHDR", "iCCP", "PLTE", "IDAT", "IEND"])
    #expect(decoded.iccProfile?.name == "Display P3")
    #expect(decoded.iccProfile?.data == profile)
}

/// DEFLATE's stored blocks (RFC 1951, 3.2.4): valid, uncompressed, and enough to check the container around them.
@Sendable func storedDeflate(_ data: Data) -> Data {
    var out = Data()
    var start = data.startIndex
    repeat {
        let end = min(start + 65535, data.endIndex)
        let length = UInt16(end - start)
        out.append(end == data.endIndex ? 1 : 0)
        out.append(contentsOf: [UInt8(length & 0xFF), UInt8(length >> 8), UInt8(~length & 0xFF), UInt8(~length >> 8)])
        out.append(data[start..<end])
        start = end
    } while start < data.endIndex
    return out
}

private struct DecodedPNG {
    var chunkTypes: [String] = []
    var width = 0
    var height = 0
    var colorType: UInt8 = 0
    var palette: [UInt32] = []
    var transparency: [UInt8] = []
    var indices: [UInt8] = []
    var iccProfile: (name: String, data: Data)?

    struct Malformed: Error { let reason: String }

    init(_ png: Data) throws {
        let bytes = [UInt8](png)
        guard bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) else { throw Malformed(reason: "no PNG signature") }
        var offset = 8
        var depth = 8
        var idat = Data()
        while offset < bytes.count {
            let length = Int(Self.uint32(bytes, offset))
            let typeAndBody = Data(bytes[offset + 4..<offset + 8 + length])
            guard Self.uint32(bytes, offset + 8 + length) == IndexedPNG.crc32(typeAndBody) else { throw Malformed(reason: "bad CRC") }
            let type = String(decoding: typeAndBody.prefix(4), as: UTF8.self)
            let body = [UInt8](typeAndBody.dropFirst(4))
            chunkTypes.append(type)
            switch type {
            case "IHDR":
                (width, height, depth, colorType) = (Int(Self.uint32(body, 0)), Int(Self.uint32(body, 4)), Int(body[8]), body[9])
            case "PLTE":
                palette = stride(from: 0, to: body.count, by: 3).map { UInt32(body[$0]) << 24 | UInt32(body[$0 + 1]) << 16 | UInt32(body[$0 + 2]) << 8 }
            case "tRNS":
                transparency = body
            case "iCCP":
                let nameEnd = body.firstIndex(of: 0)!
                iccProfile = (String(decoding: body[..<nameEnd], as: UTF8.self), try Self.inflateStored(zlib: Data(body[(nameEnd + 2)...])))
            case "IDAT":
                idat.append(Data(body))
            default:
                break
            }
            offset += 12 + length
        }
        let rows = [UInt8](try Self.inflateStored(zlib: idat))
        let rowBytes = (width * depth + 7) / 8
        for row in 0..<height {
            let start = row * (rowBytes + 1)
            guard rows[start] == 0 else { throw Malformed(reason: "row \(row) uses filter \(rows[start])") }
            for column in 0..<width {
                let bit = column * depth
                let byte = rows[start + 1 + bit / 8]
                indices.append(byte >> UInt8(8 - depth - bit % 8) & UInt8((1 << depth) - 1))
            }
        }
    }

    private static func uint32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        bytes[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func inflateStored(zlib: Data) throws -> Data {
        let bytes = [UInt8](zlib)
        guard bytes.count >= 6, (UInt16(bytes[0]) << 8 | UInt16(bytes[1])) % 31 == 0 else { throw Malformed(reason: "bad zlib header") }
        var out = Data()
        var offset = 2
        var final = false
        while !final {
            final = bytes[offset] & 1 == 1
            let length = Int(bytes[offset + 1]) | Int(bytes[offset + 2]) << 8
            out.append(contentsOf: bytes[offset + 5..<offset + 5 + length])
            offset += 5 + length
        }
        guard uint32(bytes, offset) == IndexedPNG.adler32(out) else { throw Malformed(reason: "bad Adler-32") }
        return out
    }
}
