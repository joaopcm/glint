import Foundation
import CoreGraphics
import CoreVideo
import Testing
@testable import LunettaCapture

func page(width: Int, height: Int) -> Frame {
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let offset = (y * width + x) * 4
            if x == 0 {
                pixels[offset] = UInt8(truncatingIfNeeded: y)
                pixels[offset + 1] = UInt8(truncatingIfNeeded: y >> 8)
                pixels[offset + 2] = UInt8(truncatingIfNeeded: y >> 16)
            } else {
                let mixed = UInt32(truncatingIfNeeded: y) &* 2_654_435_761 ^ UInt32(truncatingIfNeeded: x) &* 40_503
                pixels[offset] = UInt8(truncatingIfNeeded: mixed)
                pixels[offset + 1] = UInt8(truncatingIfNeeded: mixed >> 8)
                pixels[offset + 2] = UInt8(truncatingIfNeeded: mixed >> 16)
            }
        }
    }
    return Frame(width: width, height: height, bytesPerRow: width * 4, pixels: pixels)
}

func viewport(of page: Frame, top: Int, height: Int, header: Int = 0, footer: Int = 0, sidebar: Int = 0) -> Frame {
    let width = page.width
    var pixels = Array(page.pixels[(top * width * 4)..<((top + height) * width * 4)])

    func paint(rows: Range<Int>, columns: Range<Int>, seed: UInt8) {
        for y in rows {
            for x in columns {
                let offset = (y * width + x) * 4
                pixels[offset] = seed &+ UInt8(truncatingIfNeeded: x &* 3 &+ y)
                pixels[offset + 1] = seed ^ UInt8(truncatingIfNeeded: x)
                pixels[offset + 2] = seed &+ UInt8(truncatingIfNeeded: y)
                pixels[offset + 3] = 255
            }
        }
    }

    paint(rows: 0..<height, columns: 0..<sidebar, seed: 11)
    paint(rows: 0..<header, columns: 0..<width, seed: 53)
    paint(rows: (height - footer)..<height, columns: 0..<width, seed: 97)
    return Frame(width: width, height: height, bytesPerRow: width * 4, pixels: pixels)
}

private func solid(width: Int, height: Int, value: UInt8 = 7) -> Frame {
    Frame(width: width, height: height, bytesPerRow: width * 4, pixels: [UInt8](repeating: value, count: width * height * 4))
}

private func set(_ frame: Frame, x: Int, y: Int, to value: UInt8) -> Frame {
    var pixels = frame.pixels
    let offset = y * frame.bytesPerRow + x * 4
    pixels.replaceSubrange(offset..<(offset + 4), with: [UInt8](repeating: value, count: 4))
    return Frame(width: frame.width, height: frame.height, bytesPerRow: frame.bytesPerRow, pixels: pixels)
}

@Test func identicalRowsShareASignature() {
    let source = page(width: 64, height: 300)
    let a = viewport(of: source, top: 40, height: 100)
    let b = viewport(of: source, top: 40, height: 100)
    let signatures = a.rowSignatures(columns: 0..<64, stride: 3)
    #expect(signatures == b.rowSignatures(columns: 0..<64, stride: 3))
    #expect(Set(signatures).count == signatures.count)
}

@Test func shiftedFrameSignaturesLineUp() {
    let source = page(width: 64, height: 300)
    let a = viewport(of: source, top: 0, height: 100)
    let b = viewport(of: source, top: 10, height: 100)
    let aRows = a.rowSignatures(columns: 0..<64, stride: 1)
    let bRows = b.rowSignatures(columns: 0..<64, stride: 1)
    #expect(Array(aRows[10...]) == Array(bRows[..<90]))
}

@Test func strideStillSeesLastPixel() {
    let base = solid(width: 52, height: 2)
    let frame = set(base, x: 51, y: 1, to: 200)
    let rows = frame.rowSignatures(columns: 0..<52, stride: 7)
    #expect(rows[0] != rows[1])
}

@Test func strideSkipsPixelsBetweenSamples() {
    let base = solid(width: 52, height: 2)
    let frame = set(base, x: 3, y: 1, to: 200)
    let rows = frame.rowSignatures(columns: 0..<52, stride: 7)
    #expect(rows[0] == rows[1])
}

@Test func columnSignaturesLineUpAcrossColumnShift() {
    let source = page(width: 64, height: 100)
    let whole = source.columnSignatures(stride: 1)
    let shifted = source.cropped(columns: 5..<64, rows: 0..<100).columnSignatures(stride: 1)
    #expect(Array(whole[5...]) == shifted)
    #expect(Set(whole).count == whole.count)
}

@Test func columnStrideStillSeesLastRow() {
    let base = solid(width: 2, height: 52)
    let frame = set(base, x: 1, y: 51, to: 200)
    let columns = frame.columnSignatures(stride: 7)
    #expect(columns[0] != columns[1])
}

@Test func uniformRowAndColumnNeedEveryPixelIdentical() {
    let frame = set(solid(width: 8, height: 6), x: 2, y: 4, to: 200)
    #expect(frame.isUniformRow(3, columns: 0..<8))
    #expect(!frame.isUniformRow(4, columns: 0..<8))
    #expect(frame.isUniformRow(4, columns: 3..<8))
    #expect(frame.isUniformColumn(1))
    #expect(!frame.isUniformColumn(2))
}

@Test func croppedKeepsTheRequestedPixels() {
    let source = page(width: 20, height: 30)
    let crop = source.cropped(columns: 4..<12, rows: 10..<25)
    #expect(crop.width == 8)
    #expect(crop.height == 15)
    #expect(crop.bytesPerRow == 32)
    for y in 0..<15 {
        let sourceStart = (10 + y) * source.bytesPerRow + 4 * 4
        #expect(Array(crop.pixels[(y * 32)..<(y * 32 + 32)]) == Array(source.pixels[sourceStart..<(sourceStart + 32)]))
    }
}

@Test func frameRoundTripsCGImage() throws {
    let width = 9, height = 5
    var rgba = [UInt8](repeating: 255, count: width * height * 4)
    for i in 0..<(width * height) {
        rgba[i * 4] = UInt8(i * 5)
        rgba[i * 4 + 1] = UInt8(i * 3)
        rgba[i * 4 + 2] = UInt8(i)
    }
    let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    let provider = CGDataProvider(data: Data(rgba) as CFData)!
    let image = try #require(CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: sRGB,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
    ))

    var expected = [UInt8](repeating: 0, count: width * height * 4)
    expected.withUnsafeMutableBytes { buffer in
        let context = CGContext(
            data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }

    let frame = try #require(Frame(image))
    let all = frame.cropped(columns: 0..<width, rows: 0..<height)
    #expect(all.pixels == expected)
    #expect(Array(all.pixels[0..<4]) == [rgba[2], rgba[1], rgba[0], 255])
    #expect(Array(all.pixels[4..<8]) == [rgba[6], rgba[5], rgba[4], 255])
}

@Test func frameReadsBGRAPixelBufferWithPaddedRows() throws {
    let width = 5, height = 3
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
    let pixelBuffer = try #require(buffer)
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let base = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
    var expected: [UInt8] = []
    for y in 0..<height {
        for i in 0..<(width * 4) {
            let value = UInt8(y * 40 + i)
            base[y * stride + i] = value
            expected.append(value)
        }
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

    let frame = try #require(Frame(pixelBuffer))
    #expect(frame.width == width)
    #expect(frame.height == height)
    #expect(frame.pixels == expected)
}

@Test func frameRejectsNonBGRAPixelBuffer() throws {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, 4, 4, kCVPixelFormatType_32ARGB, nil, &buffer)
    #expect(Frame(try #require(buffer)) == nil)
}
