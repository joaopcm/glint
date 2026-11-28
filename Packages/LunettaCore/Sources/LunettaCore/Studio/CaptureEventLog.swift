import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public enum CaptureEvent: Codable, Equatable, Sendable {
    case pointer(t: Double, x: Double, y: Double)
    case cursor(t: Double, image: String, hotspotX: Double, hotspotY: Double)
    case click(t: Double, x: Double, y: Double)
    case key(t: Double, label: String)
    case bubble(t: Double, frame: CGRect)
    case window(t: Double, frame: CGRect)

    var time: Double {
        switch self {
        case .pointer(let t, _, _), .cursor(let t, _, _, _), .click(let t, _, _), .key(let t, _), .bubble(let t, _), .window(let t, _):
            t
        }
    }
}

public struct CursorShape: Equatable, Sendable {
    public let image: String
    public let hotspot: CGPoint

    public init(image: String, hotspot: CGPoint) {
        self.image = image
        self.hotspot = hotspot
    }
}

public struct CaptureEventLog: Equatable, Sendable {
    private struct Timed<Value: Equatable & Sendable>: Equatable, Sendable {
        let t: Double
        let value: Value
    }

    private var pointers: [Timed<CGPoint>] = []
    private var cursors: [Timed<CursorShape>] = []
    private var clickList: [Timed<CGPoint>] = []
    private var keys: [Timed<String>] = []
    private var bubbles: [Timed<CGRect>] = []
    private var windows: [Timed<CGRect>] = []

    public init(_ events: [CaptureEvent]) {
        for event in events {
            switch event {
            case .pointer(let t, let x, let y): pointers.append(Timed(t: t, value: CGPoint(x: x, y: y)))
            case .cursor(let t, let image, let hx, let hy): cursors.append(Timed(t: t, value: CursorShape(image: image, hotspot: CGPoint(x: hx, y: hy))))
            case .click(let t, let x, let y): clickList.append(Timed(t: t, value: CGPoint(x: x, y: y)))
            case .key(let t, let label): keys.append(Timed(t: t, value: label))
            case .bubble(let t, let frame): bubbles.append(Timed(t: t, value: frame))
            case .window(let t, let frame): windows.append(Timed(t: t, value: frame))
            }
        }
        pointers = Self.sorted(pointers)
        cursors = Self.sorted(cursors)
        clickList = Self.sorted(clickList)
        keys = Self.sorted(keys)
        bubbles = Self.sorted(bubbles)
        windows = Self.sorted(windows)
    }

    public static func read(jsonLines: Data) -> CaptureEventLog {
        let decoder = JSONDecoder()
        let events = jsonLines
            .split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
            .compactMap { try? decoder.decode(CaptureEvent.self, from: Data($0)) }
        return CaptureEventLog(events)
    }

    public func pointer(at t: Double) -> CGPoint? {
        guard let index = Self.lastIndex(in: pointers, atOrBefore: t) else { return nil }
        let previous = pointers[index]
        guard index + 1 < pointers.count else { return previous.value }
        let next = pointers[index + 1]
        let span = next.t - previous.t
        guard span > 0 else { return next.value }
        let fraction = (t - previous.t) / span
        return CGPoint(
            x: previous.value.x + (next.value.x - previous.value.x) * fraction,
            y: previous.value.y + (next.value.y - previous.value.y) * fraction
        )
    }

    public func cursor(at t: Double) -> CursorShape? {
        Self.lastIndex(in: cursors, atOrBefore: t).map { cursors[$0].value }
    }

    public func clicks(in range: ClosedRange<Double>) -> [(t: Double, point: CGPoint)] {
        clickList
            .filter { range.contains($0.t) }
            .map { (t: $0.t, point: $0.value) }
    }

    public func key(at t: Double) -> (label: String, age: Double)? {
        guard let index = Self.lastIndex(in: keys, atOrBefore: t) else { return nil }
        let age = t - keys[index].t
        guard age <= OverlayStyle.keysLinger + OverlayStyle.exitDuration else { return nil }
        return (keys[index].value, age)
    }

    public func bubbleFrame(at t: Double) -> CGRect? {
        Self.lastIndex(in: bubbles, atOrBefore: t).map { bubbles[$0].value }
    }

    public func windowFrame(at t: Double) -> CGRect? {
        Self.lastIndex(in: windows, atOrBefore: t).map { windows[$0].value }
    }

    private static func sorted<Value>(_ list: [Timed<Value>]) -> [Timed<Value>] {
        list.enumerated()
            .sorted { ($0.element.t, $0.offset) < ($1.element.t, $1.offset) }
            .map(\.element)
    }

    private static func lastIndex<Value>(in list: [Timed<Value>], atOrBefore t: Double) -> Int? {
        var low = 0
        var high = list.count
        while low < high {
            let mid = (low + high) / 2
            if list[mid].t <= t { low = mid + 1 } else { high = mid }
        }
        return low == 0 ? nil : low - 1
    }
}

public final class CaptureEventWriter {
    private let handle: FileHandle
    private let encoder = JSONEncoder()

    public init(file: URL) throws {
        if !FileManager.default.fileExists(atPath: file.path) {
            guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path])
            }
        }
        handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
    }

    public func append(_ event: CaptureEvent) throws {
        var line = try encoder.encode(event)
        line.append(UInt8(ascii: "\n"))
        try handle.write(contentsOf: line)
    }

    public func close() throws {
        try handle.close()
    }
}
