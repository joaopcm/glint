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

public struct StageChrome: Equatable, Sendable {
    public let toolbar: CGRect
    public let labelLane: CGRect
    public let notice: CGRect?
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
    /// the area instead of stopping it, like the first drag did. `keepingAspectRatio` (⇧) makes a grip scale the area
    /// instead of stretching it.
    public static func rect(for drag: StageDrag, pointer: CGPoint, bounds: CGRect, keepingAspectRatio: Bool = false) -> CGRect {
        let clamped = CGPoint(x: min(max(pointer.x, bounds.minX), bounds.maxX), y: min(max(pointer.y, bounds.minY), bounds.maxY))
        switch drag {
        case .draw(let start):
            return spanning(start, clamped)
        case .move(let start, let grab):
            let x = min(max(start.minX + pointer.x - grab.x, bounds.minX), bounds.maxX - start.width)
            let y = min(max(start.minY + pointer.y - grab.y, bounds.minY), bounds.maxY - start.height)
            return CGRect(x: x, y: y, width: start.width, height: start.height)
        case .resize(let handle, let start) where keepingAspectRatio && start.width > 0 && start.height > 0:
            return scaled(start, by: handle, pointer: clamped, bounds: bounds)
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

    /// The gap between the toolbar and a hover label, the same as over the recording controls.
    public static let labelGap: CGFloat = 6

    /// Places the toolbar, the lane its hover labels show in, and a problem notice. The toolbar sits next to the area,
    /// the lane on its far side, and the notice past the lane, so neither a label nor the notice covers the area. Room
    /// for the lane is kept whether or not a label shows, so hovering never moves the toolbar.
    public static func chrome(
        toolbar size: CGSize,
        labelHeight: CGFloat,
        notice noticeSize: CGSize?,
        region: CGRect,
        visible: CGRect,
        gap: CGFloat
    ) -> StageChrome {
        let laneHeight = labelHeight + labelGap
        let block = RecordingGeometry.controlBarFrame(
            size: CGSize(width: size.width, height: size.height + laneHeight), region: region, visible: visible, gap: gap
        )
        let belowRegion = block.midY < region.midY
        let toolbar = CGRect(x: block.minX, y: belowRegion ? block.maxY - size.height : block.minY, width: size.width, height: size.height)
        let laneY = belowRegion ? block.minY : toolbar.maxY + labelGap
        let lane = CGRect(x: visible.minX + gap, y: laneY, width: visible.width - 2 * gap, height: labelHeight)
        let notice = noticeSize.map {
            noticeFrame(size: $0, toolbar: CGRect(x: toolbar.minX, y: block.minY, width: toolbar.width, height: block.height), region: region, visible: visible, gap: 8)
        }
        return StageChrome(toolbar: toolbar, labelLane: lane, notice: notice)
    }

    /// A hover label centered over its button, slid along the lane to stay on screen.
    public static func labelFrame(size: CGSize, over buttonMidX: CGFloat, in lane: CGRect) -> CGRect {
        let x = min(max(buttonMidX - size.width / 2, lane.minX), lane.maxX - size.width)
        return CGRect(x: x, y: lane.minY, width: size.width, height: size.height)
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

    /// Scales `start` from the grip opposite `handle` by whichever axis the pointer pulled further, as Figma and Keynote
    /// do. A corner grows away from the opposite corner; an edge grows away from the opposite edge and keeps the other
    /// axis centered. The scale stops where the area would leave `bounds`.
    private static func scaled(_ start: CGRect, by handle: StageHandle, pointer: CGPoint, bounds: CGRect) -> CGRect {
        let anchor = point(of: opposite(handle), on: start)
        let grip = point(of: handle, on: start)
        let movesX = grip.x != anchor.x
        let movesY = grip.y != anchor.y
        let dx = pointer.x - anchor.x
        let dy = pointer.y - anchor.y
        let growsRight = (dx == 0 ? grip.x - anchor.x : dx) >= 0
        let growsUp = (dy == 0 ? grip.y - anchor.y : dy) >= 0

        let wanted = max(movesX ? abs(dx) / start.width : 0, movesY ? abs(dy) / start.height : 0)
        let roomX = if movesX {
            growsRight ? bounds.maxX - anchor.x : anchor.x - bounds.minX
        } else {
            2 * min(start.midX - bounds.minX, bounds.maxX - start.midX)
        }
        let roomY = if movesY {
            growsUp ? bounds.maxY - anchor.y : anchor.y - bounds.minY
        } else {
            2 * min(start.midY - bounds.minY, bounds.maxY - start.midY)
        }
        let scale = min(wanted, roomX / start.width, roomY / start.height)

        let width = start.width * scale
        let height = start.height * scale
        let x = movesX ? (growsRight ? anchor.x : anchor.x - width) : start.midX - width / 2
        let y = movesY ? (growsUp ? anchor.y : anchor.y - height) : start.midY - height / 2
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func spanning(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }
}
