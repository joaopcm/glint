import AVFoundation
import CoreImage
import Foundation
import ImageIO
import LunettaCore
import Synchronization
import Testing
import UniformTypeIdentifiers
@testable import LunettaStudio

private let fps: Int32 = 30
private let screenSize = PixelSize(width: 320, height: 240)
private let area = CGRect(x: 100, y: 100, width: 320, height: 240)
private let partStarts = [1000.0, 2000.0]
private let bubble = CGRect(x: 120, y: 120, width: 80, height: 80)
private let bt709: [String: String] = [
    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
]

/// A project folder with two 2 s parts, a camera clip on part 1 that starts 0.5 s in, and a cursor at the area's center.
private struct Fixture {
    let root: URL
    var project: RecordingProject

    var folder: URL { root.appending(path: "project") }
    var output: URL { root.appending(path: "saved/Recording.mp4") }
    var scratch: URL { folder.appending(path: "render.mp4") }

    static func make() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "LunettaExport-\(UUID().uuidString)")
        let folder = root.appending(path: "project")
        try FileManager.default.createDirectory(at: folder.appending(path: "cursors"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "saved"), withIntermediateDirectories: true)
        try writeCursor(to: folder.appending(path: "cursors/arrow.png"))
        var parts: [ProjectPart] = []
        for (index, start) in partStarts.enumerated() {
            let n = index + 1
            let part = ProjectPart(
                screen: "part-\(n).screen.mp4",
                camera: n == 1 ? "part-1.camera.mov" : nil,
                events: "part-\(n).events.jsonl",
                screenStartHostTime: start,
                cameraStartHostTime: n == 1 ? start + 0.5 : nil
            )
            try await writeScreen(to: folder.appending(path: part.screen))
            try writeEvents([
                .pointer(t: start, x: 260, y: 220),
                .cursor(t: start, image: "arrow.png", hotspotX: 1, hotspotY: 1),
                .bubble(t: start, frame: bubble),
            ], to: folder.appending(path: part.events))
            parts.append(part)
        }
        try await writeCamera(to: folder.appending(path: "part-1.camera.mov"))
        let project = RecordingProject(
            id: UUID(),
            createdAt: Date(),
            mode: .area,
            region: area,
            windowID: nil,
            parts: parts,
            overlays: ProjectOverlays(clicks: true, keys: true, camera: true, clickColorHex: "#FF0000", cameraMirrored: false),
            output: ProjectOutput(file: root.appending(path: "saved/Recording.mp4"), codec: .h264, frameRate: .thirty, capsToUHD: true)
        )
        return Fixture(root: root, project: project)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func render(budget: MemoryBudget = .unlimited, progress: @Sendable (Double) -> Void = { _ in }) async throws(RenderError) {
        let composition = try await ProjectComposition.make(project: project, folder: folder)
        try await ProjectExporter.export(
            composition, codec: .h264, frameRate: .thirty, to: output, scratch: scratch, budget: budget, progress: progress
        )
    }

    /// The screen's gray as the raw part decodes, which the export should pass through untouched.
    func screenPixel() async throws -> RGB {
        try await ExportedFrame(folder.appending(path: "part-1.screen.mp4"), at: 1).at(60, 60)
    }

    var leftNothingBehind: Bool {
        !FileManager.default.fileExists(atPath: output.path) && !FileManager.default.fileExists(atPath: scratch.path)
    }
}

private func writeCursor(to url: URL) throws {
    let canvas = try #require(CGContext(
        data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    canvas.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
    canvas.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try #require(canvas.makeImage()), nil)
    #expect(CGImageDestinationFinalize(destination))
}

private func writeEvents(_ events: [CaptureEvent], to url: URL) throws {
    let writer = try CaptureEventWriter(file: url)
    for event in events { try writer.append(event) }
    try writer.close()
}

/// 2 s of mid gray at 30 fps with a 1 kHz tone, like a raw screen part.
private func writeScreen(to url: URL) async throws {
    try await writeMovie(to: url, type: .mp4, size: screenSize, color: { _ in RGB(r: 128, g: 128, b: 128) }, withTone: true)
}

private func writeCamera(to url: URL, color: (_ frame: Int) -> RGB = { _ in RGB(r: 255, g: 0, b: 0) }) async throws {
    try await writeMovie(to: url, type: .mov, size: PixelSize(width: 160, height: 120), color: color, withTone: false)
}

private func writeMovie(to url: URL, type: AVFileType, size: PixelSize, color: (_ frame: Int) -> RGB, withTone: Bool) async throws {
    let frames = Int(fps) * 2
    let sampleRate = 48_000
    let writer = try AVAssetWriter(outputURL: url, fileType: type)
    let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: size.width,
        AVVideoHeightKey: size.height,
        AVVideoColorPropertiesKey: bt709,
    ])
    video.expectsMediaDataInRealTime = true
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: size.width,
        kCVPixelBufferHeightKey as String: size.height,
    ])
    writer.add(video)
    let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 1,
    ])
    audio.expectsMediaDataInRealTime = true
    if withTone { writer.add(audio) }
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    let samplesPerFrame = sampleRate / Int(fps)
    for frame in 0..<frames {
        while !video.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, try #require(adaptor.pixelBufferPool), &buffer)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        let rowBytes = CVPixelBufferGetBytesPerRow(pixels)
        let base = try #require(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
        let fill = color(frame)
        for y in 0..<size.height {
            for x in 0..<size.width {
                let pixel = base + y * rowBytes + x * 4
                pixel[0] = UInt8(fill.b)
                pixel[1] = UInt8(fill.g)
                pixel[2] = UInt8(fill.r)
                pixel[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        #expect(adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps)))
        if withTone {
            while !audio.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            #expect(audio.append(try tone(from: frame * samplesPerFrame, count: samplesPerFrame, sampleRate: sampleRate)))
        }
    }
    video.markAsFinished()
    if withTone { audio.markAsFinished() }
    writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frames), timescale: fps))
    await writer.finishWriting()
    #expect(writer.status == .completed, "\(writer.error?.localizedDescription ?? "")")
}

private func tone(from first: Int, count: Int, sampleRate: Int) throws -> CMSampleBuffer {
    var description = AudioStreamBasicDescription(
        mSampleRate: Double(sampleRate), mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
        mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0
    )
    var format: CMAudioFormatDescription?
    CMAudioFormatDescriptionCreate(
        allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
        formatDescriptionOut: &format
    )
    let samples = (first..<first + count).map { Int16(sin(2 * .pi * 1000 * Double($0) / Double(sampleRate)) * 8000) }
    var block: CMBlockBuffer?
    CMBlockBufferCreateWithMemoryBlock(
        allocator: nil, memoryBlock: nil, blockLength: count * 2, blockAllocator: nil, customBlockSource: nil,
        offsetToData: 0, dataLength: count * 2, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
    )
    let data = try #require(block)
    samples.withUnsafeBytes { bytes in
        _ = CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: data, offsetIntoDestination: 0, dataLength: count * 2)
    }
    var buffer: CMSampleBuffer?
    CMAudioSampleBufferCreateReadyWithPacketDescriptions(
        allocator: nil, dataBuffer: data, formatDescription: try #require(format), sampleCount: count,
        presentationTimeStamp: CMTime(value: CMTimeValue(first), timescale: CMTimeScale(sampleRate)),
        packetDescriptions: nil, sampleBufferOut: &buffer
    )
    return try #require(buffer)
}

private struct RGB {
    let r, g, b: Int

    func matches(_ other: RGB) -> Bool { abs(r - other.r) <= 3 && abs(g - other.g) <= 3 && abs(b - other.b) <= 3 }
    var isCursorBlack: Bool { r <= 30 && g <= 30 && b <= 30 }
    var isCameraRed: Bool { r >= 200 && g <= 60 && b <= 60 }
}

/// A frame of the exported file, probed in Core Image's bottom-left coordinates.
private struct ExportedFrame {
    let width, height: Int
    let bytes: [UInt8]

    init(_ url: URL, at seconds: Double) async throws {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        width = image.width
        height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return context != nil
        }
        #expect(drawn)
        self.bytes = bytes
    }

    func at(_ x: Int, _ y: Int) -> RGB {
        let offset = ((height - 1 - y) * width + x) * 4
        return RGB(r: Int(bytes[offset]), g: Int(bytes[offset + 1]), b: Int(bytes[offset + 2]))
    }
}

@Test func overTheBudgetNamesTheBudgetTheLimitAndTheAsk() throws {
    let uhd = PixelSize(width: 3840, height: 2160)
    let error = #expect(throws: RenderError.self) {
        try MemoryBudget(limitMB: 100).check(output: uhd, footprintMB: { 150 })
    }
    #expect(error == .overMemoryBudget(limitMB: 100, usedMB: 150, output: uhd))
    let message = try #require(error?.errorDescription)
    for part in ["render memory budget", "100 MB", "150 MB", "3840x2160", "docs/perf/2026-11-28-render.md"] {
        #expect(message.contains(part), "\(message)")
    }
}

@Test func underTheBudgetPasses() throws {
    try MemoryBudget(limitMB: 100).check(output: screenSize, footprintMB: { 100 })
    try MemoryBudget.unlimited.check(output: screenSize)
}

@Test func anExportHasBothPartsBackToBackAtTheChosenFrameRate() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.remove() }

    try await fixture.render()

    let asset = AVURLAsset(url: fixture.output)
    let duration = try await asset.load(.duration).seconds
    #expect(abs(duration - 4) <= 1 / Double(fps) + 0.001, "\(duration)")
    let videos = try await asset.loadTracks(withMediaType: .video)
    #expect(videos.count == 1)
    let rate = try await #require(videos.first).load(.nominalFrameRate)
    #expect(abs(rate - 30) < 0.01, "\(rate)")
    #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
    #expect(!FileManager.default.fileExists(atPath: fixture.scratch.path))
}

@Test func progressGoesFromZeroToOne() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.remove() }
    let reported = Mutex<[Double]>([])

    try await fixture.render { value in reported.withLock { $0.append(value) } }

    let values = reported.withLock { $0 }
    #expect(values.first == 0)
    #expect(values.last == 1)
    #expect(values.count > 2)
    #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
}

@Test func aFailedExportLeavesNothingAtTheOutput() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.remove() }
    try FileManager.default.removeItem(at: fixture.folder.appending(path: "part-2.screen.mp4"))

    await #expect(throws: RenderError.missingMedia(file: "part-2.screen.mp4")) { try await fixture.render() }

    #expect(fixture.leftNothingBehind)
}

@Test func goingOverTheBudgetMidExportLeavesNothingBehind() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.remove() }

    let error = await #expect(throws: RenderError.self) { try await fixture.render(budget: MemoryBudget(limitMB: 1)) }

    guard case let .overMemoryBudget(limitMB, usedMB, output) = error else {
        Issue.record("expected overMemoryBudget, got \(String(describing: error))")
        return
    }
    #expect(limitMB == 1)
    #expect(usedMB > 1)
    #expect(output == screenSize)
    #expect(fixture.leftNothingBehind)
}

@Test func aCancelledExportLeavesNothingBehind() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.remove() }
    let export = Mutex<Task<Void, any Error>?>(nil)
    let (go, letGo) = AsyncStream.makeStream(of: Void.self)

    let task = Task {
        for await _ in go { break }
        try await fixture.render { value in
            if value > 0 { export.withLock { $0?.cancel() } }
        }
    }
    export.withLock { $0 = task }
    letGo.yield()

    await #expect(throws: RenderError.writerFailed("cancelled")) { try await task.value }
    #expect(fixture.leftNothingBehind)
}

@Test func aSecondExportReplacesTheFirst() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.remove() }
    try Data("an older render".utf8).write(to: fixture.output)

    try await fixture.render()

    #expect(try await AVURLAsset(url: fixture.output).load(.duration).seconds > 3.9)
}

@Test func aFrameFromTheExportShowsTheCursor() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.remove() }

    try await fixture.render()

    // (260, 220) global is (160, 120) in the frame; the 8x8 cursor with a (1, 1) hotspot covers x 159..166, y 113..120.
    let frame = try await ExportedFrame(fixture.output, at: 1)
    let screen = try await fixture.screenPixel()
    #expect(frame.width == 320 && frame.height == 240)
    #expect(frame.at(162, 116).isCursorBlack, "\(frame.at(162, 116))")
    #expect(frame.at(162, 140).matches(screen), "\(frame.at(162, 140)) vs \(screen)")

    let secondPart = try await ExportedFrame(fixture.output, at: 3)
    #expect(secondPart.at(162, 116).isCursorBlack, "\(secondPart.at(162, 116))")
}

@Test func theCameraStartsWhereItsPartSaysItDid() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.remove() }

    try await fixture.render()

    // The bubble covers x 20..99, y 20..99 in the frame. The camera started 0.5 s into part 1 and part 2 has none.
    let screen = try await fixture.screenPixel()
    let before = try await ExportedFrame(fixture.output, at: 0.25)
    #expect(before.at(60, 60).matches(screen), "\(before.at(60, 60)) vs \(screen)")
    let during = try await ExportedFrame(fixture.output, at: 1)
    #expect(during.at(60, 60).isCameraRed, "\(during.at(60, 60))")
    let partWithoutCamera = try await ExportedFrame(fixture.output, at: 3)
    #expect(partWithoutCamera.at(60, 60).matches(screen), "\(partWithoutCamera.at(60, 60)) vs \(screen)")
}

@Test func aCameraThatStartedBeforeItsPartShowsWhereItWasAtThePartsStart() async throws {
    var fixture = try await Fixture.make()
    defer { fixture.remove() }
    try FileManager.default.removeItem(at: fixture.folder.appending(path: "part-1.camera.mov"))
    try await writeCamera(to: fixture.folder.appending(path: "part-1.camera.mov")) { frame in
        frame < Int(fps) / 2 ? RGB(r: 0, g: 0, b: 255) : RGB(r: 255, g: 0, b: 0)
    }
    fixture.project.parts[0].cameraStartHostTime = partStarts[0] - 0.5

    try await fixture.render()

    for seconds in [0.0, 0.25] {
        let frame = try await ExportedFrame(fixture.output, at: seconds)
        #expect(frame.at(60, 60).isCameraRed, "\(seconds) s: \(frame.at(60, 60))")
    }
}

@Test func aMissingCursorImageFailsNamingIt() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.remove() }
    try FileManager.default.removeItem(at: fixture.folder.appending(path: "cursors/arrow.png"))

    await #expect(throws: RenderError.missingMedia(file: "cursors/arrow.png")) { try await fixture.render() }
    #expect(fixture.leftNothingBehind)
}

@Test func aMissingCameraClipFailsNamingIt() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.remove() }
    try FileManager.default.removeItem(at: fixture.folder.appending(path: "part-1.camera.mov"))

    await #expect(throws: RenderError.missingMedia(file: "part-1.camera.mov")) { try await fixture.render() }
}

@Test func anUnreadableClickColorFails() async throws {
    var fixture = try await Fixture.make()
    defer { fixture.remove() }
    fixture.project.overlays.clickColorHex = "#+F0000"

    let error = await #expect(throws: RenderError.self) { try await fixture.render() }
    #expect(error?.errorDescription?.contains("#+F0000") == true)
}

