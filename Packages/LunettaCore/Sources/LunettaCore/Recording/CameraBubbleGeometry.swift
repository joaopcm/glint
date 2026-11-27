import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Where the camera bubble sits in a recorded area and how big it is, in AppKit coordinates. Moving or resizing it never
/// takes it past the area's edges, so every frame of the recording holds the whole bubble.
public enum CameraBubbleGeometry {
    /// 240 pt across a whole 1512 × 982 pt MacBook Air screen covers 3.0% of the frame (π · 120² / (1512 · 982)).
    public static let defaultDiameter: CGFloat = 240
    /// 96 pt leaves a 68 pt middle to move it by inside the edge that resizes it, more than twice a 28 pt toolbar button.
    public static let minDiameter: CGFloat = 96
    /// At 2x, 360 pt is 720 px: the height of the 1280 × 720 frames the camera delivers, so the image is never upscaled.
    public static let maxDiameter: CGFloat = 360
    /// The stage's grip radius (`StageGeometry.handleHitRadius`), so the edge is as easy to catch as the stage's grips.
    public static let edgeWidth: CGFloat = 14
    /// The pressed keys' inset from the area's bottom (`KeystrokeOverlay.bottomInset`), so both sit on one margin.
    public static let inset: CGFloat = 24

    /// Up to half the area's shorter side, so the bubble covers at most π / 16 ≈ 20% of a square area.
    public static func diameters(in region: CGRect) -> ClosedRange<CGFloat> {
        let upper = min(maxDiameter, min(region.width, region.height) / 2)
        return min(minDiameter, upper)...upper
    }

    public static func clampedDiameter(_ diameter: CGFloat, in region: CGRect) -> CGFloat {
        let range = diameters(in: region)
        return min(max(diameter, range.lowerBound), range.upperBound)
    }

    /// The bottom-right corner, away from where text starts in a left-to-right layout.
    public static func initialFrame(in region: CGRect, diameter: CGFloat = defaultDiameter) -> CGRect {
        let side = clampedDiameter(diameter, in: region)
        let frame = CGRect(x: region.maxX - inset - side, y: region.minY + inset, width: side, height: side)
        return clamped(frame, within: region)
    }

    /// True on the ring along the circle's edge, where a press resizes instead of moving.
    public static func isOnEdge(_ point: CGPoint, of frame: CGRect) -> Bool {
        let radius = frame.width / 2
        let distance = hypot(point.x - frame.midX, point.y - frame.midY)
        return distance <= radius && distance >= radius - edgeWidth
    }

    public static func dragged(_ frame: CGRect, by offset: CGPoint, within region: CGRect) -> CGRect {
        clamped(frame.offsetBy(dx: offset.x, dy: offset.y), within: region)
    }

    /// Grows or shrinks around the center by as much as the pointer moved away from or toward it since `grab`, so the
    /// edge stays under the pointer. Past the area's edges the bubble shifts back in rather than getting cut off.
    public static func resized(_ frame: CGRect, grabbedAt grab: CGPoint, pointer: CGPoint, within region: CGRect) -> CGRect {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let reach = hypot(pointer.x - center.x, pointer.y - center.y) - hypot(grab.x - center.x, grab.y - center.y)
        let side = clampedDiameter(frame.width + 2 * reach, in: region)
        return clamped(CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side), within: region)
    }

    public static func clamped(_ frame: CGRect, within region: CGRect) -> CGRect {
        var frame = frame
        frame.origin.x = max(region.minX, min(frame.minX, region.maxX - frame.width))
        frame.origin.y = max(region.minY, min(frame.minY, region.maxY - frame.height))
        return frame
    }
}
