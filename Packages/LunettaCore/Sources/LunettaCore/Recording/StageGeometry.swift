import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// The eight grips on the staged area's edges, in AppKit coordinates (y up, so `top` is `maxY`).
public enum StageHandle: CaseIterable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
}

/// What a press on the stage starts: resizing from a grip, moving the area, or drawing a new one.
public enum StageDrag: Equatable, Sendable {
    case resize(StageHandle, from: CGRect)
    case move(from: CGRect, grab: CGPoint)
    case draw(from: CGPoint)
}

public enum StageGeometry {
    /// Half of a toolbar button's 28 pt side (`Glass.buttonSide`), so a grip is as easy to hit as a button.
    public static let handleHitRadius: CGFloat = 14

    public static func point(of handle: StageHandle, on rect: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .top: CGPoint(x: rect.midX, y: rect.maxY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.maxY)
        case .right: CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .bottom: CGPoint(x: rect.midX, y: rect.minY)
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .left: CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    /// Grips win over the inside, so the corners of a small area still resize it.
    public static func handle(at point: CGPoint, on rect: CGRect) -> StageHandle? {
        StageHandle.allCases
            .map { ($0, hypot(point.x - Self.point(of: $0, on: rect).x, point.y - Self.point(of: $0, on: rect).y)) }
            .filter { $0.1 <= handleHitRadius }
            .min { $0.1 < $1.1 }?.0
    }

    public static func drag(startingAt point: CGPoint, on rect: CGRect) -> StageDrag {
        if let handle = handle(at: point, on: rect) { return .resize(handle, from: rect) }
        if rect.contains(point) { return .move(from: rect, grab: point) }
        return .draw(from: point)
    }

    /// The area while the pointer is at `pointer`, kept inside `bounds`. Dragging a grip past the opposite edge flips
    /// the area instead of stopping it, like the first drag did.
    public static func rect(for drag: StageDrag, pointer: CGPoint, bounds: CGRect) -> CGRect {
        let clamped = CGPoint(x: min(max(pointer.x, bounds.minX), bounds.maxX), y: min(max(pointer.y, bounds.minY), bounds.maxY))
        switch drag {
        case .draw(let start):
            return spanning(start, clamped)
        case .move(let start, let grab):
            let x = min(max(start.minX + pointer.x - grab.x, bounds.minX), bounds.maxX - start.width)
            let y = min(max(start.minY + pointer.y - grab.y, bounds.minY), bounds.maxY - start.height)
            return CGRect(x: x, y: y, width: start.width, height: start.height)
        case .resize(let handle, let start):
            let anchor = point(of: opposite(handle), on: start)
            switch handle {
            case .top, .bottom:
                return spanning(CGPoint(x: start.minX, y: anchor.y), CGPoint(x: start.maxX, y: clamped.y))
            case .left, .right:
                return spanning(CGPoint(x: anchor.x, y: start.minY), CGPoint(x: clamped.x, y: start.maxY))
            case .topLeft, .topRight, .bottomRight, .bottomLeft:
                return spanning(anchor, clamped)
            }
        }
    }

    /// Arrow keys nudge the area without letting it leave `bounds`.
    public static func nudge(_ area: CGRect, by offset: CGPoint, in bounds: CGRect) -> CGRect {
        rect(for: .move(from: area, grab: .zero), pointer: offset, bounds: bounds)
    }

    /// Where a problem notice sits: on the far side of the toolbar from the area, so it never covers what's recorded,
    /// and on the near side when the far side runs off the screen.
    public static func noticeFrame(size: CGSize, toolbar: CGRect, region: CGRect, visible: CGRect, gap: CGFloat) -> CGRect {
        let toolbarBelowRegion = toolbar.midY < region.midY
        let below = toolbar.minY - gap - size.height
        let above = toolbar.maxY + gap
        let y: CGFloat = if toolbarBelowRegion {
            below >= visible.minY ? below : above
        } else {
            above + size.height <= visible.maxY ? above : below
        }
        let x = min(max(toolbar.midX - size.width / 2, visible.minX + gap), visible.maxX - gap - size.width)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    private static func opposite(_ handle: StageHandle) -> StageHandle {
        switch handle {
        case .topLeft: .bottomRight
        case .top: .bottom
        case .topRight: .bottomLeft
        case .right: .left
        case .bottomRight: .topLeft
        case .bottom: .top
        case .bottomLeft: .topRight
        case .left: .right
        }
    }

    private static func spanning(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }
}
