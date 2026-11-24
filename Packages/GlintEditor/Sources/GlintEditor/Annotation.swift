import CoreGraphics
import Foundation

public struct Annotation: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case arrow
        case rectangle
        case text(String)
        case highlighter
        case blur
        case pixelate
    }

    public enum Handle: CaseIterable, Sendable {
        case start, end
    }

    public let id: UUID
    public var kind: Kind
    public var start: CGPoint
    public var end: CGPoint
    public var lineWidth: CGFloat

    public init(id: UUID = UUID(), kind: Kind, start: CGPoint, end: CGPoint, lineWidth: CGFloat) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end
        self.lineWidth = lineWidth
    }

    public var bounds: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    public func point(of handle: Handle) -> CGPoint {
        handle == .start ? start : end
    }

    public func moved(by delta: CGSize) -> Annotation {
        var moved = self
        moved.start = CGPoint(x: start.x + delta.width, y: start.y + delta.height)
        moved.end = CGPoint(x: end.x + delta.width, y: end.y + delta.height)
        return moved
    }

    public func resized(_ handle: Handle, to point: CGPoint) -> Annotation {
        var resized = self
        switch handle {
        case .start: resized.start = point
        case .end: resized.end = point
        }
        return resized
    }

    public func contains(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        switch kind {
        case .arrow:
            return distance(from: point, toSegment: start, end) <= lineWidth / 2 + tolerance
        case .rectangle, .text, .highlighter, .blur, .pixelate:
            return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }
    }

    private func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}
