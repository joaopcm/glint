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

    /// The border sits just outside the recorded region, so it never covers what is being recorded.
    public static func borderFrame(around region: CGRect, lineWidth: CGFloat) -> CGRect {
        region.insetBy(dx: -lineWidth, dy: -lineWidth)
    }
}
