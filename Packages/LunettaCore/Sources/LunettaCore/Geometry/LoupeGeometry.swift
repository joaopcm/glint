import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public struct LoupePixel: Sendable, Equatable {
    public let x: Int
    public let y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
}

public enum LoupeGeometry {
    public static func frame(size: CGSize, pointer: CGPoint, in screen: CGRect, offset: CGFloat) -> CGRect {
        var x = pointer.x + offset
        if x + size.width > screen.maxX {
            x = pointer.x - offset - size.width
        }
        var y = pointer.y - offset - size.height
        if y < screen.minY {
            y = pointer.y + offset
        }
        x = min(max(x, screen.minX), screen.maxX - size.width)
        y = min(max(y, screen.minY), screen.maxY - size.height)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    /// The display pixel under a global AppKit point, counted from the display's top-left.
    public static func pixel(at pointer: CGPoint, on display: DisplayInfo) -> LoupePixel {
        let (width, height) = DisplayGeometry.pixelSize(of: display.frame, scale: display.scale)
        let x = Int(((pointer.x - display.frame.minX) * display.scale).rounded(.down))
        let y = Int(((display.frame.maxY - pointer.y) * display.scale).rounded(.down))
        return LoupePixel(x: min(max(x, 0), width - 1), y: min(max(y, 0), height - 1))
    }
}
