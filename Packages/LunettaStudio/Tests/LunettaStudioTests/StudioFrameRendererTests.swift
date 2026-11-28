import CoreImage
import Foundation
import ImageIO
import LunettaCore
import Testing
import UniformTypeIdentifiers
@testable import LunettaStudio

private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
private let context = CIContext(options: [.useSoftwareRenderer: true, .outputColorSpace: sRGB])

private struct RGBA {
    let r, g, b: Int

    var isScreenGray: Bool { abs(r - 128) <= 2 && abs(g - 128) <= 2 && abs(b - 128) <= 2 }
    var isCursorBlack: Bool { r <= 2 && g <= 2 && b <= 2 }
}

/// Pixels read in Core Image's bottom-left coordinates, from a rendered window of the frame.
private struct Rendered {
    let window: CGRect
    let bytes: [UInt8]

    init(_ image: CIImage, window: CGRect) {
        self.window = window
        let width = Int(window.width)
        let height = Int(window.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            context.render(image, toBitmap: buffer.baseAddress!, rowBytes: width * 4, bounds: window, format: .RGBA8, colorSpace: sRGB)
        }
        self.bytes = bytes
    }

    func at(_ x: Int, _ y: Int) -> RGBA {
        let column = x - Int(window.minX)
        let row = Int(window.maxY) - 1 - y
        let offset = (row * Int(window.width) + column) * 4
        return RGBA(r: Int(bytes[offset]), g: Int(bytes[offset + 1]), b: Int(bytes[offset + 2]))
    }
}

private func render(_ image: CIImage, size: PixelSize) -> Rendered {
    Rendered(image, window: CGRect(x: 0, y: 0, width: size.width, height: size.height))
}

private let area = CGRect(x: 100, y: 100, width: 400, height: 300)
private let sourceSize = PixelSize(width: 400, height: 300)

private func gray(_ size: PixelSize) -> CIImage {
    CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: size.width, height: size.height))
}

private func split(left: CIColor, right: CIColor, width: CGFloat = 160, height: CGFloat = 120) -> CIImage {
    let leftHalf = CIImage(color: left).cropped(to: CGRect(x: 0, y: 0, width: width / 2, height: height))
    let rightHalf = CIImage(color: right).cropped(to: CGRect(x: width / 2, y: 0, width: width / 2, height: height))
    return rightHalf.composited(over: leftHalf)
}

private func cursorFolder(pixels: Int = 8, dpi: Double? = nil) throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cursors-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let canvas = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels * 4,
        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    canvas.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
    canvas.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    let destination = CGImageDestinationCreateWithURL(folder.appendingPathComponent("arrow.png") as CFURL, UTType.png.identifier as CFString, 1, nil)!
    let properties = dpi.map { [kCGImagePropertyDPIWidth: $0, kCGImagePropertyDPIHeight: $0] as CFDictionary }
    CGImageDestinationAddImage(destination, canvas.makeImage()!, properties)
    #expect(CGImageDestinationFinalize(destination))
    return folder
}

private func project(
    mode: RecordingMode = .area,
    region: CGRect = area,
    overlays: ProjectOverlays = ProjectOverlays(clicks: true, keys: true, camera: true, clickColorHex: "#FF0000", cameraMirrored: false),
    parts: Int = 1
) -> RecordingProject {
    RecordingProject(
        id: UUID(),
        createdAt: Date(),
        mode: mode,
        region: region,
        windowID: mode == .window ? 42 : nil,
        parts: (1...parts).map { index in
            ProjectPart(screen: "part-\(index).screen.mp4", camera: nil, events: "part-\(index).events.jsonl", screenStartHostTime: 0, cameraStartHostTime: nil)
        },
        overlays: overlays,
        output: ProjectOutput(file: URL(fileURLWithPath: "/tmp/out.mp4"), codec: .h264, frameRate: .thirty, capsToUHD: true)
    )
}

private func renderer(
    _ project: RecordingProject,
    events: [[CaptureEvent]],
    cursors: URL? = nil,
    source: PixelSize = sourceSize,
    output: PixelSize = sourceSize
) throws -> StudioFrameRenderer {
    StudioFrameRenderer(
        project: project,
        logs: events.map(CaptureEventLog.init),
        cursors: CursorImageLibrary(folder: try cursors ?? cursorFolder()),
        sourceSize: source,
        outputSize: output
    )
}

private let arrowAt300x250: [CaptureEvent] = [
    .pointer(t: 0, x: 300, y: 250),
    .cursor(t: 0, image: "arrow.png", hotspotX: 1, hotspotY: 1),
]

@Test func theCursorLandsAtTheLoggedPointMinusItsHotspot() throws {
    let studio = try renderer(project(), events: [arrowAt300x250])
    let frame = render(studio.frame(screen: gray(sourceSize), camera: nil, part: 0, hostTime: 1), size: sourceSize)

    // (300, 250) global is (200, 150) in the frame; a top-left hotspot of (1, 1) puts the 8x8 image at x 199..206, y 143..150.
    #expect(frame.at(199, 150).isCursorBlack)
    #expect(frame.at(206, 143).isCursorBlack)
    #expect(frame.at(198, 150).isScreenGray)
    #expect(frame.at(199, 151).isScreenGray)
    #expect(frame.at(207, 143).isScreenGray)
    #expect(frame.at(206, 142).isScreenGray)
}

@Test func aRetinaCursorKeepsItsPointSize() throws {
    let retina = PixelSize(width: 800, height: 600)
    let studio = try renderer(project(), events: [arrowAt300x250], cursors: cursorFolder(pixels: 16, dpi: 144), source: retina, output: retina)
    let frame = render(studio.frame(screen: gray(retina), camera: nil, part: 0, hostTime: 1), size: retina)

    // 8 pt at 2 px per point: 16 px wide from (400 - 2, 300 + 2) down.
    #expect(frame.at(398, 301).isCursorBlack)
    #expect(frame.at(413, 286).isCursorBlack)
    #expect(frame.at(397, 301).isScreenGray)
    #expect(frame.at(414, 286).isScreenGray)
    #expect(frame.at(413, 285).isScreenGray)
}

@Test func theCameraIsAMirroredCircleWhereTheBubbleIs() throws {
    let mirrored = ProjectOverlays(clicks: false, keys: false, camera: true, clickColorHex: "#FF0000", cameraMirrored: true)
    let studio = try renderer(project(overlays: mirrored), events: [[.bubble(t: 0, frame: CGRect(x: 300, y: 150, width: 100, height: 100))]])
    let camera = split(left: CIColor(red: 1, green: 0, blue: 0), right: CIColor(red: 0, green: 0, blue: 1))
    let frame = render(studio.frame(screen: gray(sourceSize), camera: camera, part: 0, hostTime: 1), size: sourceSize)

    // The bubble covers x 200..299, y 50..149 in the frame, centered on (250, 100).
    let left = frame.at(225, 100)
    let right = frame.at(275, 100)
    #expect(left.b > 240 && left.r < 15)
    #expect(right.r > 240 && right.b < 15)
    for corner in [frame.at(201, 51), frame.at(298, 51), frame.at(201, 148), frame.at(298, 148)] {
        #expect(corner.isScreenGray)
    }
    #expect(frame.at(199, 100).isScreenGray)
    #expect(frame.at(300, 100).isScreenGray)

    let border = frame.at(200, 100)
    #expect(border.b > 240 && border.r > 30 && border.r < 200)
}

@Test func theCameraFollowsTheBubbleWhenItMoves() throws {
    let a = CGRect(x: 120, y: 120, width: 80, height: 80)
    let b = CGRect(x: 380, y: 280, width: 80, height: 80)
    let studio = try renderer(project(), events: [[.bubble(t: 1, frame: a), .bubble(t: 2, frame: b)]])
    let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 160, height: 120))

    let early = render(studio.frame(screen: gray(sourceSize), camera: red, part: 0, hostTime: 1.5), size: sourceSize)
    #expect(early.at(60, 60).r > 240)
    #expect(early.at(320, 220).isScreenGray)

    let late = render(studio.frame(screen: gray(sourceSize), camera: red, part: 0, hostTime: 2.5), size: sourceSize)
    #expect(late.at(60, 60).isScreenGray)
    #expect(late.at(320, 220).r > 240)
}

@Test func aPartWithoutCameraRendersWithoutTheBubble() throws {
    let bubble: [CaptureEvent] = [.bubble(t: 0, frame: CGRect(x: 300, y: 150, width: 100, height: 100))]
    let studio = try renderer(project(parts: 2), events: [bubble, bubble + arrowAt300x250])
    let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 160, height: 120))

    let withCamera = render(studio.frame(screen: gray(sourceSize), camera: red, part: 0, hostTime: 1), size: sourceSize)
    #expect(withCamera.at(250, 100).r > 240)

    let withoutCamera = render(studio.frame(screen: gray(sourceSize), camera: nil, part: 1, hostTime: 1), size: sourceSize)
    #expect(withoutCamera.at(250, 100).isScreenGray)
    #expect(withoutCamera.at(199, 150).isCursorBlack)
}

@Test func keysShowWhileTheyLingerAndAreGoneAfter() throws {
    let studio = try renderer(project(), events: [[.key(t: 10, label: "⌘K")]])

    // The capsule is 52 pt tall, 24 pt above the area's bottom, centered: y 24..75 around x 200. Text sits mid-height.
    let shown = render(studio.frame(screen: gray(sourceSize), camera: nil, part: 0, hostTime: 10.5), size: sourceSize)
    #expect(shown.at(200, 27).g < 80)
    #expect(shown.at(200, 73).g < 80)
    #expect(shown.at(200, 22).isScreenGray)
    #expect(shown.at(200, 77).isScreenGray)
    #expect(shown.at(120, 50).isScreenGray)

    let fading = render(studio.frame(screen: gray(sourceSize), camera: nil, part: 0, hostTime: 11.6), size: sourceSize)
    #expect(fading.at(200, 27).g > shown.at(200, 27).g + 20)
    #expect(fading.at(200, 27).g < 118)

    let gone = render(studio.frame(screen: gray(sourceSize), camera: nil, part: 0, hostTime: 11.8), size: sourceSize)
    #expect(gone.at(200, 27).isScreenGray)
}

@Test func aClickRingPulsesAndFades() throws {
    let studio = try renderer(project(), events: [[.click(t: 5, x: 300, y: 250)]])

    // At 0.05 s the eased disc is about 22 pt across, so (200, 150) is inside and 14 pt to the right is not yet.
    let pulsing = render(studio.frame(screen: gray(sourceSize), camera: nil, part: 0, hostTime: 5.05), size: sourceSize)
    let center = pulsing.at(200, 150)
    #expect(center.r > center.g + 15)
    #expect(pulsing.at(214, 150).isScreenGray)

    let faded = render(studio.frame(screen: gray(sourceSize), camera: nil, part: 0, hostTime: 5.5), size: sourceSize)
    #expect(faded.at(200, 150).isScreenGray)
}

@Test func clicksStayOffWhenTheProjectHasThemOff() throws {
    let noClicks = ProjectOverlays(clicks: false, keys: false, camera: false, clickColorHex: "#FF0000", cameraMirrored: false)
    let studio = try renderer(project(overlays: noClicks), events: [[.click(t: 5, x: 300, y: 250)]])

    let frame = render(studio.frame(screen: gray(sourceSize), camera: nil, part: 0, hostTime: 5.05), size: sourceSize)
    #expect(frame.at(200, 150).isScreenGray)
}

@Test func theCursorFollowsAMovingWindowAndHidesOutsideIt() throws {
    let noOverlays = ProjectOverlays(clicks: false, keys: false, camera: false, clickColorHex: "#FF0000", cameraMirrored: false)
    let events: [CaptureEvent] = [
        .window(t: 0, frame: area),
        .window(t: 2, frame: CGRect(x: 500, y: 400, width: 400, height: 300)),
        .cursor(t: 0, image: "arrow.png", hotspotX: 1, hotspotY: 1),
        .pointer(t: 0, x: 300, y: 250),
        .pointer(t: 1.5, x: 300, y: 250),
        .pointer(t: 2, x: 700, y: 550),
        .pointer(t: 3.5, x: 700, y: 550),
        .pointer(t: 4, x: 503, y: 550),
        .pointer(t: 4.5, x: 503, y: 550),
        .pointer(t: 5, x: 498, y: 550),
    ]
    let studio = try renderer(project(mode: .window, overlays: noOverlays), events: [events])

    let before = render(studio.frame(screen: gray(sourceSize), camera: nil, part: 0, hostTime: 1), size: sourceSize)
    #expect(before.at(199, 150).isCursorBlack)

    let moved = render(studio.frame(screen: gray(sourceSize), camera: nil, part: 0, hostTime: 3), size: sourceSize)
    #expect(moved.at(199, 150).isCursorBlack)

    // 3 pt inside the window's left edge: the cursor spans x 2..9.
    let insideEdge = render(studio.frame(screen: gray(sourceSize), camera: nil, part: 0, hostTime: 4.2), size: sourceSize)
    #expect(insideEdge.at(4, 147).isCursorBlack)

    // 2 pt outside: drawn, it would cover x 0..4.
    let outside = render(studio.frame(screen: gray(sourceSize), camera: nil, part: 0, hostTime: 5), size: sourceSize)
    #expect(outside.at(2, 147).isScreenGray)
}

@Test func aWindowRecordedInPlaceDrawsEverythingAgainstItsFixedCrop() throws {
    let moved = CGRect(x: 500, y: 400, width: 400, height: 300)
    let events: [CaptureEvent] = [
        .window(t: 0, frame: area),
        .window(t: 1, frame: moved),
        .bubble(t: 0, frame: CGRect(x: 380, y: 300, width: 80, height: 80)),
        .cursor(t: 0, image: "arrow.png", hotspotX: 1, hotspotY: 1),
        .pointer(t: 0, x: 98, y: 250),
        .click(t: 5, x: 300, y: 250),
        .key(t: 5, label: "⌘S"),
    ]
    let studio = try renderer(project(mode: .area, region: area), events: [events])
    let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 160, height: 120))
    let frame = render(studio.frame(screen: gray(sourceSize), camera: red, part: 0, hostTime: 5.05), size: sourceSize)

    // Against the crop the bubble centers on (320, 240), the ring on (200, 150) and the keys capsule spans y 24..75 at x 200.
    #expect(frame.at(320, 240).r > 240)
    let ring = frame.at(200, 150)
    #expect(ring.r > ring.g + 15)
    #expect(frame.at(200, 27).g < 80)
    // 2 pt left of the crop, the cursor's right edge still shows, as it would in the filmed crop of the display.
    #expect(frame.at(2, 147).isCursorBlack)
}

@Test func outputScalesTheWholeFrame() throws {
    let source = PixelSize(width: 6016, height: 3384)
    let output = PixelSize(width: 3840, height: 2160)
    let screen = CGRect(x: 0, y: 0, width: 3008, height: 1692)
    let events: [CaptureEvent] = [
        .pointer(t: 0, x: 1504, y: 846),
        .cursor(t: 0, image: "arrow.png", hotspotX: 1, hotspotY: 1),
    ]
    let studio = try renderer(project(region: screen), events: [events], source: source, output: output)
    let image = studio.frame(screen: gray(source), camera: nil, part: 0, hostTime: 1)

    #expect(image.extent == CGRect(x: 0, y: 0, width: 3840, height: 2160))

    // (1504, 846) lands on (1920, 1080); 8 pt is 16 source px, 10.2 output px; the (1, 1) hotspot is 1.28 output px.
    let near = Rendered(image, window: CGRect(x: 1900, y: 1060, width: 40, height: 40))
    #expect(near.at(1920, 1078).isCursorBlack)
    #expect(near.at(1927, 1073).isCursorBlack)
    #expect(near.at(1917, 1078).isScreenGray)
    #expect(near.at(1930, 1078).isScreenGray)
    #expect(near.at(1920, 1082).isScreenGray)
    #expect(near.at(1920, 1069).isScreenGray)

    let corner = Rendered(image, window: CGRect(x: 3830, y: 2150, width: 10, height: 10))
    #expect(corner.at(3839, 2159).isScreenGray)
}
