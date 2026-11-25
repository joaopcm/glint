import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public enum RecordingGeometry {
    /// The H.264 and HEVC encoders pad odd frame sizes: a 401 × 301 px request came out 402 × 302 px
    /// (SCRecordingOutput probe on macOS 27.2, PR for #17). Trimming the last odd pixel row and column
    /// keeps the file exactly the size of what it shows.
    public static func evenPixelRegion(of sourceRect: CGRect, scale: CGFloat) -> (sourceRect: CGRect, width: Int, height: Int)? {
        let size = DisplayGeometry.pixelSize(of: sourceRect, scale: scale)
        let width = size.width & ~1
        let height = size.height & ~1
        guard width > 0, height > 0 else { return nil }
        let trimmed = CGRect(x: sourceRect.minX, y: sourceRect.minY, width: CGFloat(width) / scale, height: CGFloat(height) / scale)
        return (trimmed, width, height)
    }

    /// Where the recording controls sit, in AppKit coordinates (y up): centered under the recorded region, above it
    /// when there is no room below, and along its bottom edge when it fills the screen. Lunetta's own windows stay out
    /// of every recording, so the last case covers nothing in the file, only on screen.
    public static func controlBarFrame(size: CGSize, region: CGRect, visible: CGRect, gap: CGFloat) -> CGRect {
        let below = region.minY - gap - size.height
        let above = region.maxY + gap
        let y: CGFloat = if below >= visible.minY {
            below
        } else if above + size.height <= visible.maxY {
            above
        } else {
            max(region.minY, visible.minY) + gap
        }
        let centeredX = region.midX - size.width / 2
        let x = min(max(centeredX, visible.minX + gap), visible.maxX - gap - size.width)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// The countdown sits in the middle of the region, pulled back on screen when the region runs off it.
    public static func countdownCenter(size: CGSize, region: CGRect, visible: CGRect) -> CGPoint {
        let clamped = region.intersection(visible).isNull ? visible : region.intersection(visible)
        let x = min(max(clamped.midX, visible.minX + size.width / 2), visible.maxX - size.width / 2)
        let y = min(max(clamped.midY, visible.minY + size.height / 2), visible.maxY - size.height / 2)
        return CGPoint(x: x, y: y)
    }
}
