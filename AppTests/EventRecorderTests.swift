import AppKit
import CoreMedia
import ImageIO
import LunettaCore
import QuartzCore
import Testing
@testable import Lunetta

@MainActor
private struct Fixture {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("event-recorder-\(UUID().uuidString)")
    let logFile: URL
    let cursorsFolder: URL
    let writer: CaptureEventWriter

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        logFile = folder.appendingPathComponent("events.jsonl")
        cursorsFolder = folder.appendingPathComponent("cursors")
        writer = try CaptureEventWriter(file: logFile)
    }

    func events() throws -> [CaptureEvent] {
        let decoder = JSONDecoder()
        return try Data(contentsOf: logFile)
            .split(separator: UInt8(ascii: "\n"))
            .map { try decoder.decode(CaptureEvent.self, from: Data($0)) }
    }

    func pngCount() -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: cursorsFolder.path)) ?? []).filter { $0.hasSuffix(".png") }.count
    }

    func remove() {
        try? FileManager.default.removeItem(at: folder)
    }
}

@MainActor
@Test func onlyChangesAreLogged() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let recorder = EventRecorder(
        writer: fixture.writer,
        cursors: CursorImageStore(folder: fixture.cursorsFolder),
        windowID: nil,
        pointer: { CGPoint(x: 10, y: 20) },
        cursor: { nil }
    )

    recorder.tick()
    recorder.tick()
    recorder.tick()
    try recorder.stop()

    let events = try fixture.events()
    #expect(events.count == 1)
    guard case .pointer(_, let x, let y) = events[0] else {
        Issue.record("expected a pointer event, got \(events[0])")
        return
    }
    #expect(x == 10 && y == 20)
}

@MainActor
@Test func aNewCursorShapeWritesItsImageOnce() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    var current = NSCursor.arrow
    let recorder = EventRecorder(
        writer: fixture.writer,
        cursors: CursorImageStore(folder: fixture.cursorsFolder),
        windowID: nil,
        pointer: { .zero },
        cursor: { current }
    )

    recorder.tick()
    current = .iBeam
    recorder.tick()
    current = .arrow
    recorder.tick()
    try recorder.stop()

    let cursorEvents = try fixture.events().compactMap { event -> String? in
        if case .cursor(_, let image, _, _) = event { image } else { nil }
    }
    #expect(cursorEvents.count == 3)
    #expect(cursorEvents[0] == cursorEvents[2])
    #expect(cursorEvents[0] != cursorEvents[1])
    #expect(fixture.pngCount() == 2)
}

@MainActor
@Test func windowRecordingsLogTheWindowFrameWhenItMoves() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    var frame = CGRect(x: 0, y: 0, width: 400, height: 300)
    var asked: [UInt32] = []
    let recorder = EventRecorder(
        writer: fixture.writer,
        cursors: CursorImageStore(folder: fixture.cursorsFolder),
        windowID: 42,
        pointer: { .zero },
        cursor: { nil },
        windowFrame: { id in asked.append(id); return frame }
    )

    recorder.tick()
    recorder.tick()
    frame = frame.offsetBy(dx: 50, dy: 0)
    recorder.tick()
    try recorder.stop()

    let frames = try fixture.events().compactMap { event -> CGRect? in
        if case .window(_, let frame) = event { frame } else { nil }
    }
    #expect(frames == [CGRect(x: 0, y: 0, width: 400, height: 300), CGRect(x: 50, y: 0, width: 400, height: 300)])
    #expect(Set(asked) == [42])
}

@MainActor
@Test func areaRecordingsNeverLogAWindowFrame() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let recorder = EventRecorder(
        writer: fixture.writer,
        cursors: CursorImageStore(folder: fixture.cursorsFolder),
        windowID: nil,
        pointer: { .zero },
        cursor: { nil },
        windowFrame: { _ in CGRect(x: 0, y: 0, width: 1, height: 1) }
    )

    recorder.tick()
    try recorder.stop()

    #expect(try fixture.events().allSatisfy { if case .window = $0 { false } else { true } })
}

@MainActor
@Test func keysAndBubblesAreStampedWithTheClock() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    var time = 5.0
    let recorder = EventRecorder(
        writer: fixture.writer,
        cursors: CursorImageStore(folder: fixture.cursorsFolder),
        windowID: nil,
        now: { time },
        pointer: { .zero },
        cursor: { nil }
    )

    recorder.logKey("⌘C")
    time = 6
    recorder.logBubble(CGRect(x: 1, y: 2, width: 3, height: 4))
    try recorder.stop()

    #expect(try fixture.events() == [
        .key(t: 5, label: "⌘C"),
        .bubble(t: 6, frame: CGRect(x: 1, y: 2, width: 3, height: 4)),
    ])
}

@MainActor
@Test func aCursorImageKeepsItsRetinaPixelsAtItsPointSize() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let pointSize = NSSize(width: 16, height: 16)
    let retina = try #require(NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ))
    retina.size = pointSize
    let image = NSImage(size: pointSize)
    image.addRepresentation(retina)
    let store = CursorImageStore(folder: fixture.cursorsFolder)

    let name = try store.name(for: NSCursor(image: image, hotSpot: NSPoint(x: 3, y: 4)))

    let source = try #require(CGImageSourceCreateWithURL(fixture.cursorsFolder.appendingPathComponent(name) as CFURL, nil))
    let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    let pixels = try #require(properties[kCGImagePropertyPixelWidth] as? Double)
    let dpi = try #require(properties[kCGImagePropertyDPIWidth] as? Double)
    #expect(pixels == 32)
    #expect(abs(pixels * 72 / dpi - pointSize.width) < 0.05)
}

@Test func theHostClockMatchesScreenCaptureKitsClock() {
    #expect(abs(CACurrentMediaTime() - CMClockGetTime(CMClockGetHostTimeClock()).seconds) < 0.001)
}
