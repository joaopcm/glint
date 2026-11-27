import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Where the camera bubble sits in a recorded area, in AppKit coordinates. A drag can take it anywhere in the area but
/// never past its edges, so every frame of the recording holds the whole bubble.
public enum CameraBubbleGeometry {
    /// 180 pt across a whole 1512 × 982 pt MacBook Air screen covers 1.7% of the frame (π · 90² / (1512 · 982)). At 2x
    /// it is 360 px, inside the 480 px height of the VGA frames the camera delivers, so the image is never upscaled.
    public static let maxDiameter: CGFloat = 180
    /// The pressed keys' inset from the area's bottom (`KeystrokeOverlay.bottomInset`), so both sit on one margin.
    public static let inset: CGFloat = 24

    /// A quarter of the area's shorter side below the cap, so the bubble covers at most π / 64 ≈ 4.9% of a square area.
    public static func diameter(in region: CGRect) -> CGFloat {
        min(maxDiameter, min(region.width, region.height) / 4)
    }

    /// The bottom-right corner, away from where text starts in a left-to-right layout.
    public static func initialFrame(in region: CGRect) -> CGRect {
        let side = diameter(in: region)
        let frame = CGRect(x: region.maxX - inset - side, y: region.minY + inset, width: side, height: side)
        return clamped(frame, within: region)
    }

    public static func dragged(_ frame: CGRect, by offset: CGPoint, within region: CGRect) -> CGRect {
        clamped(frame.offsetBy(dx: offset.x, dy: offset.y), within: region)
    }

    public static func clamped(_ frame: CGRect, within region: CGRect) -> CGRect {
        var frame = frame
        frame.origin.x = max(region.minX, min(frame.minX, region.maxX - frame.width))
        frame.origin.y = max(region.minY, min(frame.minY, region.maxY - frame.height))
        return frame
    }
}
