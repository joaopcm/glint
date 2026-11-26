import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import LunettaCapture

private func temporaryFile(_ ext: String) -> URL {
    FileManager.default.temporaryDirectory.appending(path: "LunettaCompress-\(UUID().uuidString).\(ext)")
}

/// Writes straight RGBA pixels, as `pixel(x, y)` gives them, to a PNG through ImageIO like a real capture.
private func writeScreenshot(width: Int, height: Int, pixel: (Int, Int) -> [UInt8]) throws -> URL {
    let bytes = (0..<height).flatMap { y in (0..<width).flatMap { x in pixel(x, y) } }
    let image = try #require(CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
        provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent
    ))
    let url = temporaryFile("png")
    try PNGWriter.write(image, to: url)
    return url
}

private func pixels(at url: URL) throws -> [UInt8] {
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    return try #require(CaptureCompressor.straightRGBA(of: image, in: CaptureCompressor.colorSpace(of: image).0))
}

private func fileSize(_ url: URL) throws -> Int {
    try #require(url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
}

/// 200 colors and a fully transparent one, scattered in 2 × 2 blocks so the RGBA original can't compress them away.
private func writeFewColorScreenshot(width: Int, height: Int) throws -> URL {
    var palette: [[UInt8]] = (0..<200).map { (entry: Int) -> [UInt8] in [UInt8(entry), UInt8(255 - entry), UInt8(entry * 7 % 256), 255] }
    palette.append([0, 0, 0, 0])
    return try writeScreenshot(width: width, height: height) { x, y in
        let column: Int = (x / 2) &* 73_856_093
        let row: Int = (y / 2) &* 19_349_663
        let hash = UInt32(truncatingIfNeeded: column ^ row)
        return palette[Int(hash % UInt32(palette.count))]
    }
}

@Test func aScreenshotOfFewColorsShrinksWithoutChangingAPixel() async throws {
    let url = try writeFewColorScreenshot(width: 640, height: 400)
    defer { try? FileManager.default.removeItem(at: url) }
    let before = try pixels(at: url)
    let originalSize = try fileSize(url)

    let compressed = try await CaptureCompressor.compress(url)

    let result = try #require(compressed)

    #expect(result.originalBytes == originalSize)
    #expect(result.compressedBytes == (try fileSize(url)))
    #expect(result.compressedBytes < result.originalBytes)
    #expect(try pixels(at: url) == before)
}

@Test func aScreenshotOfManyColorsKeepsAPaletteThatStaysClose() async throws {
    let url = try writeScreenshot(width: 320, height: 240) { x, y in
        let noise: Int = (x ^ y) & 15
        return [UInt8(x * 255 / 319), UInt8(y * 255 / 239), UInt8(100 + noise), 255]
    }
    defer { try? FileManager.default.removeItem(at: url) }
    let before = try pixels(at: url)

    let compressed = try await CaptureCompressor.compress(url)

    try #require(compressed != nil)

    let after = try pixels(at: url)
    #expect(Set(stride(from: 0, to: after.count, by: 4).map { after[$0..<$0 + 4] }).count <= 256)
    let errors = stride(from: 0, to: before.count, by: 4).map { pixel in
        (pixel..<pixel + 4).map { abs(Int(before[$0]) - Int(after[$0])) }.max()!
    }
    // The same 76,800 colors through PaletteQuantizer alone: 8 levels off at worst, 5.89 on average.
    #expect(errors.max()! <= 8)
    #expect(Double(errors.reduce(0, +)) / Double(errors.count) <= 6)
}

/// Its 201 colors fit the palette both times, so the second pass writes the same bytes: no smaller, nothing replaced.
@Test func compressingACompressedScreenshotAgainLeavesItAlone() async throws {
    let url = try writeFewColorScreenshot(width: 128, height: 128)
    defer { try? FileManager.default.removeItem(at: url) }
    let first = try await CaptureCompressor.compress(url)
    try #require(first != nil)
    let once = try Data(contentsOf: url)

    let second = try await CaptureCompressor.compress(url)

    #expect(second == nil)
    #expect(try Data(contentsOf: url) == once)
}

@Test func aFileImageIOCantReadFailsNamingItAndStaysPut() async throws {
    let url = temporaryFile("png")
    try Data("not a PNG".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let error = try await #require(throws: CaptureError.self) { try await CaptureCompressor.compress(url) }

    #expect(error == .compressionFailed(path: url.path, reason: "ImageIO couldn't read the screenshot"))
    #expect(error.errorDescription?.contains("kept as it was saved") == true)
    #expect(try Data(contentsOf: url) == Data("not a PNG".utf8))
}

@Test func aRecordingComesBackSmallerAndPlayableOrNotAtAll() async throws {
    let url = temporaryFile("mp4")
    try await writeMovie(codec: .h264, to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let original = try Data(contentsOf: url)

    let result = try await CaptureCompressor.compress(url)

    if let result {
        #expect(result.compressedBytes < result.originalBytes)
        #expect(result.compressedBytes == (try fileSize(url)))
    } else {
        #expect(try Data(contentsOf: url) == original)
    }
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration)
    let preset = try await CaptureCompressor.exportPreset(for: asset)
    #expect(abs(duration.seconds - 1) < 0.1)
    #expect(preset == AVAssetExportPresetHighestQuality) // still H.264
}

@Test func aRecordingIsEncodedAgainInItsOwnCodec() async throws {
    for (codec, preset) in [(AVVideoCodecType.h264, AVAssetExportPresetHighestQuality), (.hevc, AVAssetExportPresetHEVCHighestQuality)] {
        let url = temporaryFile("mp4")
        try await writeMovie(codec: codec, to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let picked = try await CaptureCompressor.exportPreset(for: AVURLAsset(url: url))
        #expect(picked == preset)
    }
}

/// One second at 30 fps of a gradient sliding sideways, encoded the way a recording is: by AVFoundation in real time.
private func writeMovie(codec: AVVideoCodecType, to url: URL) async throws {
    let (width, height) = (320, 240)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: codec, AVVideoWidthKey: width, AVVideoHeightKey: height])
    input.expectsMediaDataInRealTime = true
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
    ])
    writer.add(input)
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<30 {
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, try #require(adaptor.pixelBufferPool), &buffer)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        let rowBytes = CVPixelBufferGetBytesPerRow(pixels)
        let base = try #require(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let pixel = base + y * rowBytes + x * 4
                pixel[0] = UInt8((x + frame * 4) % 256)
                pixel[1] = UInt8(y)
                pixel[2] = 200
                pixel[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        #expect(adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30)))
    }
    input.markAsFinished()
    writer.endSession(atSourceTime: CMTime(value: 30, timescale: 30))
    await writer.finishWriting()
    #expect(writer.status == .completed, "\(writer.error?.localizedDescription ?? "")")
}
