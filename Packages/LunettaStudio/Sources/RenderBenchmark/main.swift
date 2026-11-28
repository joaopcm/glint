import AVFoundation
import Darwin
import Foundation
import ImageIO
import LunettaCore
import LunettaStudio
import UniformTypeIdentifiers

private let usage = "usage: RenderBenchmark <width>x<height> [seconds]"
private let screenFrameRate: Int32 = 60
private let cameraFrameRate: Int32 = 30
private let cameraSize = PixelSize(width: 1280, height: 720)
private let partStart = 1000.0
private let cameraDelay = 0.5

private enum Cap: String {
    case capped, full
}

private struct Case {
    let codec: VideoCodec
    let cap: Cap
}

private struct Measurement {
    let output: PixelSize
    let seconds: Double
    let peakMB: Double
}

private func peakFootprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    precondition(result == KERN_SUCCESS, "task_info(TASK_VM_INFO) failed with \(result)")
    return Double(info.ledger_phys_footprint_peak) / 1_048_576
}

private struct Pattern {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    init(width: Int, height: Int, checker: UInt8) {
        self.width = width
        self.height = height
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                pixels[offset] = UInt8(x * 255 / width)
                pixels[offset + 1] = UInt8(y * 255 / height)
                pixels[offset + 2] = ((x >> 6) ^ (y >> 6)) & 1 == 0 ? checker : 255 - checker
            }
        }
        self.pixels = pixels
    }

    func draw(frame: Int, into base: UnsafeMutablePointer<UInt8>, rowBytes: Int) {
        let columnShift = (frame * 3) % width
        let rowShift = (frame * 5) % height
        pixels.withUnsafeBufferPointer { source in
            for y in 0..<height {
                let row = source.baseAddress! + ((y + rowShift) % height) * width * 4
                let target = base + y * rowBytes
                memcpy(target, row + columnShift * 4, (width - columnShift) * 4)
                memcpy(target + (width - columnShift) * 4, row, columnShift * 4)
            }
        }
    }
}

private func writeMovie(
    to url: URL, type: AVFileType, codec: AVVideoCodecType, size: PixelSize, frameRate: Int32, seconds: Int, pattern: Pattern
) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: type)
    let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: codec,
        AVVideoWidthKey: size.width,
        AVVideoHeightKey: size.height,
        AVVideoColorPropertiesKey: [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ],
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: size.width,
        kCVPixelBufferHeightKey as String: size.height,
    ])
    writer.add(video)
    guard writer.startWriting() else { throw failure("couldn't start writing \(url.lastPathComponent): \(writer.error?.localizedDescription ?? "no reason")") }
    writer.startSession(atSourceTime: .zero)
    let frames = Int(frameRate) * seconds
    for frame in 0..<frames {
        while !video.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
        guard let pool = adaptor.pixelBufferPool else { throw failure("the writer for \(url.lastPathComponent) has no pixel buffer pool") }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let pixels = buffer else { throw failure("couldn't allocate a \(size.width)x\(size.height) pixel buffer") }
        CVPixelBufferLockBaseAddress(pixels, [])
        pattern.draw(
            frame: frame,
            into: CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self),
            rowBytes: CVPixelBufferGetBytesPerRow(pixels)
        )
        CVPixelBufferUnlockBaseAddress(pixels, [])
        guard adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: frameRate)) else {
            throw failure("couldn't append frame \(frame) to \(url.lastPathComponent): \(writer.error?.localizedDescription ?? "no reason")")
        }
    }
    video.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else { throw failure("couldn't finish \(url.lastPathComponent): \(writer.error?.localizedDescription ?? "no reason")") }
}

private func writeCursor(to url: URL) throws {
    guard let canvas = CGContext(
        data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw failure("couldn't draw the cursor image") }
    canvas.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    canvas.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
    canvas.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
    canvas.fill(CGRect(x: 2, y: 2, width: 28, height: 28))
    guard
        let image = canvas.makeImage(),
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw failure("couldn't write the cursor image") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw failure("couldn't write the cursor image") }
}

private func writeEvents(to url: URL, area: CGRect, seconds: Int) throws {
    let writer = try CaptureEventWriter(file: url)
    try writer.append(.cursor(t: partStart, image: "arrow.png", hotspotX: 2, hotspotY: 2))
    try writer.append(.bubble(t: partStart, frame: CGRect(x: 40, y: 40, width: 160, height: 160)))
    let center = CGPoint(x: area.midX, y: area.midY)
    let radius = area.height / 4
    for frame in 0..<Int(screenFrameRate) * seconds {
        let t = Double(frame) / Double(screenFrameRate)
        let angle = t * 2
        try writer.append(.pointer(t: partStart + t, x: center.x + radius * cos(angle), y: center.y + radius * sin(angle)))
        if frame % (Int(screenFrameRate) * 2) == 0 {
            try writer.append(.click(t: partStart + t, x: center.x + radius * cos(angle), y: center.y + radius * sin(angle)))
        }
        if frame % (Int(screenFrameRate) * 3) == 0 {
            try writer.append(.key(t: partStart + t, label: "⌘C"))
        }
    }
    try writer.close()
}

private func writeProject(into folder: URL, source: PixelSize, seconds: Int) async throws {
    try FileManager.default.createDirectory(at: folder.appending(path: "cursors"), withIntermediateDirectories: true)
    try writeCursor(to: folder.appending(path: "cursors/arrow.png"))
    let area = CGRect(x: 0, y: 0, width: source.width / 2, height: source.height / 2)
    try writeEvents(to: folder.appending(path: "part-1.events.jsonl"), area: area, seconds: seconds)
    try await writeMovie(
        to: folder.appending(path: "part-1.screen.mp4"), type: .mp4, codec: .hevc, size: source, frameRate: screenFrameRate,
        seconds: seconds, pattern: Pattern(width: source.width, height: source.height, checker: 40)
    )
    try await writeMovie(
        to: folder.appending(path: "part-1.camera.mov"), type: .mov, codec: .h264, size: cameraSize, frameRate: cameraFrameRate,
        seconds: seconds, pattern: Pattern(width: cameraSize.width, height: cameraSize.height, checker: 120)
    )
    let project = RecordingProject(
        id: UUID(),
        createdAt: Date(),
        mode: .area,
        region: area,
        windowID: nil,
        parts: [ProjectPart(
            screen: "part-1.screen.mp4", camera: "part-1.camera.mov", events: "part-1.events.jsonl",
            screenStartHostTime: partStart, cameraStartHostTime: partStart + cameraDelay
        )],
        overlays: ProjectOverlays(clicks: true, keys: true, camera: true, clickColorHex: "#FF0000", cameraMirrored: false),
        output: ProjectOutput(file: folder.appending(path: "Recording.mp4"), codec: .hevc, frameRate: .sixty, capsToUHD: true)
    )
    try JSONEncoder().encode(project).write(to: folder.appending(path: "project.json"))
}

private func runCase(folder: URL, codec: VideoCodec, cap: Cap) async throws {
    var project = try RecordingProject.decode(Data(contentsOf: folder.appending(path: "project.json")), file: "project.json")
    project.output.capsToUHD = cap == .capped
    let output = folder.appending(path: "export-\(codec.rawValue)-\(cap.rawValue).mp4")
    let scratch = folder.appending(path: "export-scratch.mp4")
    let start = ContinuousClock.now
    let composition = try await ProjectComposition.make(project: project, folder: folder)
    try await ProjectExporter.export(
        composition, codec: codec, frameRate: .sixty, to: output, scratch: scratch, budget: .unlimited, progress: { _ in }
    )
    let seconds = (ContinuousClock.now - start) / .seconds(1)
    try? FileManager.default.removeItem(at: output)
    print("RESULT \(composition.outputSize.width) \(composition.outputSize.height) \(seconds) \(peakFootprintMB())")
}

private func measure(_ testCase: Case, in folder: URL) throws -> Measurement {
    let child = Process()
    child.executableURL = URL(filePath: CommandLine.arguments[0])
    child.arguments = ["--case", folder.path, testCase.codec.rawValue, testCase.cap.rawValue]
    let pipe = Pipe()
    child.standardOutput = pipe
    try child.run()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    child.waitUntilExit()
    guard
        child.terminationStatus == 0,
        let line = output.split(separator: "\n").first(where: { $0.hasPrefix("RESULT ") }),
        case let fields = line.split(separator: " ").dropFirst().compactMap({ Double($0) }),
        fields.count == 4
    else { throw failure("the \(testCase.codec.rawValue) \(testCase.cap.rawValue) case exited with status \(child.terminationStatus): \(output)") }
    return Measurement(output: PixelSize(width: Int(fields[0]), height: Int(fields[1])), seconds: fields[2], peakMB: fields[3])
}

private func benchmark(source: PixelSize, seconds: Int) async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "LunettaRenderBenchmark-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    FileHandle.standardError.write(Data("writing a \(seconds) s \(source.width)x\(source.height) \(screenFrameRate) fps project to \(folder.path)\n".utf8))
    try await writeProject(into: folder, source: source, seconds: seconds)

    let capApplies = RenderSize.output(for: source, capsToUHD: true) != source
    let caps: [Cap] = capApplies ? [.capped, .full] : [.full]
    print("| source | output | codec | seconds per \(seconds) s | peak MB |")
    print("|---|---|---|---|---|")
    for cap in caps {
        for codec in VideoCodec.allCases.sorted(by: { $0 == .hevc && $1 != .hevc }) {
            let result = try measure(Case(codec: codec, cap: cap), in: folder)
            let label = capApplies ? "\(result.output.width)x\(result.output.height) (\(cap.rawValue))" : "\(result.output.width)x\(result.output.height)"
            print("| \(source.width)x\(source.height) | \(label) | \(codec == .hevc ? "HEVC" : "H.264") | \(String(format: "%.1f", result.seconds)) | \(String(format: "%.1f", result.peakMB)) |")
            fflush(stdout)
        }
    }
}

private func failure(_ message: String) -> NSError {
    NSError(domain: "RenderBenchmark", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

private func parse(size text: String) -> PixelSize? {
    let parts = text.split(separator: "x").compactMap { Int($0) }
    guard parts.count == 2, parts.allSatisfy({ $0 > 0 && $0.isMultiple(of: 2) }) else { return nil }
    return PixelSize(width: parts[0], height: parts[1])
}

private func main() async throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.count == 4, arguments[0] == "--case", let codec = VideoCodec(rawValue: arguments[2]), let cap = Cap(rawValue: arguments[3]) {
        try await runCase(folder: URL(filePath: arguments[1]), codec: codec, cap: cap)
        return
    }
    guard (1...2).contains(arguments.count), let source = parse(size: arguments[0]) else { throw failure(usage) }
    let seconds = arguments.count == 2 ? Int(arguments[1]) : 60
    guard let seconds, seconds > 0 else { throw failure(usage) }
    try await benchmark(source: source, seconds: seconds)
}

do {
    try await main()
} catch {
    FileHandle.standardError.write(Data("RenderBenchmark: \(error.localizedDescription)\n".utf8))
    exit(1)
}
