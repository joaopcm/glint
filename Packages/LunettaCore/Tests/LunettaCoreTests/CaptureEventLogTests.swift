import Foundation
import Testing
@testable import LunettaCore

struct CaptureEventLogTests {
    @Test func pointerInterpolatesBetweenSamplesAndHoldsAfterTheLast() {
        let log = CaptureEventLog([
            .pointer(t: 2, x: 10, y: 20),
            .pointer(t: 1, x: 0, y: 0),
        ])
        #expect(log.pointer(at: 1.5) == CGPoint(x: 5, y: 10))
        #expect(log.pointer(at: 3) == CGPoint(x: 10, y: 20))
        #expect(log.pointer(at: 0.5) == nil)
    }

    @Test func cursorBubbleAndWindowHoldTheirLastValue() {
        let first = CGRect(x: 0, y: 0, width: 10, height: 10)
        let second = CGRect(x: 5, y: 5, width: 20, height: 20)
        let log = CaptureEventLog([
            .cursor(t: 1, image: "a.png", hotspotX: 1, hotspotY: 2),
            .cursor(t: 3, image: "b.png", hotspotX: 3, hotspotY: 4),
            .bubble(t: 1, frame: first),
            .bubble(t: 3, frame: second),
            .window(t: 1, frame: first),
            .window(t: 3, frame: second),
        ])
        #expect(log.cursor(at: 0.9) == nil)
        #expect(log.cursor(at: 2) == CursorShape(image: "a.png", hotspot: CGPoint(x: 1, y: 2)))
        #expect(log.cursor(at: 3) == CursorShape(image: "b.png", hotspot: CGPoint(x: 3, y: 4)))
        #expect(log.bubbleFrame(at: 0.9) == nil)
        #expect(log.bubbleFrame(at: 2) == first)
        #expect(log.bubbleFrame(at: 9) == second)
        #expect(log.windowFrame(at: 0.9) == nil)
        #expect(log.windowFrame(at: 2) == first)
        #expect(log.windowFrame(at: 9) == second)
    }

    @Test func cursorImageNamesListEveryCursorTheLogShows() {
        let log = CaptureEventLog([
            .cursor(t: 1, image: "a.png", hotspotX: 0, hotspotY: 0),
            .cursor(t: 2, image: "b.png", hotspotX: 0, hotspotY: 0),
            .cursor(t: 3, image: "a.png", hotspotX: 0, hotspotY: 0),
            .pointer(t: 1, x: 0, y: 0),
        ])
        #expect(log.cursorImageNames == ["a.png", "b.png"])
        #expect(CaptureEventLog([]).cursorImageNames.isEmpty)
    }

    @Test func aKeyLingersForOverlayStyleKeysLingerPlusExit() {
        let log = CaptureEventLog([.key(t: 1, label: "A"), .key(t: 1.5, label: "B")])
        #expect(log.key(at: 0.9) == nil)
        let held = log.key(at: 1.2)
        #expect(held?.label == "A")
        #expect(abs((held?.age ?? 0) - 0.2) < 1e-9)
        #expect(log.key(at: 1.6)?.label == "B")

        let single = CaptureEventLog([.key(t: 1, label: "A")])
        #expect(single.key(at: 1 + OverlayStyle.keysLinger + OverlayStyle.exitDuration + 0.01) == nil)
    }

    @Test func clicksInARangeAreInclusive() {
        let log = CaptureEventLog([
            .click(t: 1, x: 1, y: 1),
            .click(t: 2, x: 2, y: 2),
            .click(t: 3, x: 3, y: 3),
            .click(t: 4, x: 4, y: 4),
        ])
        let found = log.clicks(in: 2...3)
        #expect(found.map(\.t) == [2, 3])
        #expect(found.map(\.point) == [CGPoint(x: 2, y: 2), CGPoint(x: 3, y: 3)])
    }

    private let sample: [CaptureEvent] = [
        .pointer(t: 1, x: 1, y: 2),
        .cursor(t: 1, image: "abc.png", hotspotX: 4, hotspotY: 5),
        .key(t: 2, label: "⌘C"),
    ]

    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("events-\(UUID().uuidString).events")
    }

    @Test func writtenLinesReadBack() throws {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let writer = try CaptureEventWriter(file: file)
        for event in sample { try writer.append(event) }
        try writer.close()

        let data = try Data(contentsOf: file)
        #expect(CaptureEventLog.read(jsonLines: data) == CaptureEventLog(sample))
        #expect(data.last == UInt8(ascii: "\n"))
    }

    @Test func aTornLastLineIsDropped() throws {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let writer = try CaptureEventWriter(file: file)
        for event in sample { try writer.append(event) }
        try writer.close()

        var data = try Data(contentsOf: file)
        data.removeLast(8)
        #expect(CaptureEventLog.read(jsonLines: data) == CaptureEventLog(Array(sample.dropLast())))
    }
}
