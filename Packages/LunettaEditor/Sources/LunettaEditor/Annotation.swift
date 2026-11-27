import CoreGraphics
import Foundation

public struct Annotation: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case arrow
        case rectangle
        case text(String)
        case highlighter
        case blur(sigma: CGFloat)
        case pixelate(block: CGFloat)

        public var usesColor: Bool {
            switch self {
            case .arrow, .rectangle, .text, .highlighter: true
            case .blur, .pixelate: false
            }
        }

        /// The blur's sigma or the pixelate's block side, in image pixels; nil for the tools that draw ink.
        public var obscuringSize: CGFloat? {
            switch self {
            case .blur(let sigma): sigma
            case .pixelate(let block): block
            case .arrow, .rectangle, .text, .highlighter: nil
            }
        }

        func obscuring(size: CGFloat) -> Kind {
            switch self {
            case .blur: .blur(sigma: size)
            case .pixelate: .pixelate(block: size)
            case .arrow, .rectangle, .text, .highlighter: self
            }
        }
    }

    public enum Handle: Sendable {
        case start, end, bend
    }

    public let id: UUID
    public var kind: Kind
    public var start: CGPoint
    public var end: CGPoint
    public var lineWidth: CGFloat
    public var color: AnnotationColor
    /// A text highlight's padded rect per line; empty for every other annotation, including a free highlight.
    public var lines: [CGRect]
    /// The point an arrow's curve passes through halfway along; nil draws it straight.
    public var bend: CGPoint?

    public init(
        id: UUID = UUID(),
        kind: Kind,
        start: CGPoint,
        end: CGPoint,
        lineWidth: CGFloat,
        color: AnnotationColor = .red,
        lines: [CGRect] = [],
        bend: CGPoint? = nil
    ) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end
        self.lineWidth = lineWidth
        self.color = color
        self.lines = lines
        self.bend = bend
    }

    public static func textHighlight(_ lines: [CGRect], color: AnnotationColor = .red, id: UUID = UUID()) -> Annotation {
        let span = lines.dropFirst().reduce(lines.first ?? .zero) { $0.union($1) }
        return Annotation(
            id: id, kind: .highlighter,
            start: CGPoint(x: span.minX, y: span.minY), end: CGPoint(x: span.maxX, y: span.maxY),
            lineWidth: 0, color: color, lines: lines
        )
    }

    public var bounds: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    public var handles: [Handle] {
        if !lines.isEmpty { return [] }
        return kind == .arrow ? [.start, .end, .bend] : [.start, .end]
    }

    public func point(of handle: Handle) -> CGPoint {
        switch handle {
        case .start: start
        case .end: end
        case .bend: bend ?? CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        }
    }

    /// The quadratic Bézier control point that makes the curve pass through `point(of: .bend)` at its midpoint.
    public var curveControl: CGPoint {
        let through = point(of: .bend)
        return CGPoint(x: 2 * through.x - (start.x + end.x) / 2, y: 2 * through.y - (start.y + end.y) / 2)
    }

    public var curve: CGPath {
        let path = CGMutablePath()
        path.move(to: start)
        path.addQuadCurve(to: end, control: curveControl)
        return path
    }

    func curvePoint(at t: CGFloat) -> CGPoint {
        let control = curveControl
        let u = 1 - t
        return CGPoint(
            x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
            y: u * u * start.y + 2 * u * t * control.y + t * t * end.y
        )
    }

    public func moved(by delta: CGSize) -> Annotation {
        var moved = self
        moved.start = CGPoint(x: start.x + delta.width, y: start.y + delta.height)
        moved.end = CGPoint(x: end.x + delta.width, y: end.y + delta.height)
        moved.bend = bend.map { CGPoint(x: $0.x + delta.width, y: $0.y + delta.height) }
        moved.lines = lines.map { $0.offsetBy(dx: delta.width, dy: delta.height) }
        return moved
    }

    public func resized(_ handle: Handle, to point: CGPoint) -> Annotation {
        var resized = self
        switch handle {
        case .start: resized.start = point
        case .end: resized.end = point
        case .bend: resized.bend = point
        }
        return resized
    }

    public func recolored(_ color: AnnotationColor) -> Annotation {
        var recolored = self
        recolored.color = color
        return recolored
    }

    public func contains(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        switch kind {
        case .arrow:
            let samples = (0...Self.curveSamples).map { curvePoint(at: CGFloat($0) / CGFloat(Self.curveSamples)) }
            let nearest = zip(samples, samples.dropFirst()).map { distance(from: point, toSegment: $0, $1) }.min() ?? .infinity
            return nearest <= lineWidth / 2 + tolerance
        case .highlighter where !lines.isEmpty:
            return lines.contains { $0.insetBy(dx: -tolerance, dy: -tolerance).contains(point) }
        case .rectangle, .text, .highlighter, .blur, .pixelate:
            return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }
    }

    /// 32 chords stay within ~0.1% of the curve's length from it: far under the hit tolerance.
    private static let curveSamples = 32

    private func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}
