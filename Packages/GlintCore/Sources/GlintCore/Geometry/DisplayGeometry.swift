import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public struct DisplayInfo: Sendable, Equatable {
    public let id: UInt32
    public let frame: CGRect
    public let scale: CGFloat

    public init(id: UInt32, frame: CGRect, scale: CGFloat) {
        self.id = id
        self.frame = frame
        self.scale = scale
    }
}

public enum DisplayGeometry {
    public static func display(containing point: CGPoint, in displays: [DisplayInfo]) -> DisplayInfo? {
        displays.first { $0.frame.contains(point) }
    }

    public static func display(nearest point: CGPoint, in displays: [DisplayInfo]) -> DisplayInfo? {
        display(containing: point, in: displays)
            ?? displays.min { squaredDistance(from: point, to: $0.frame) < squaredDistance(from: point, to: $1.frame) }
    }

    public static func appKitRect(fromTopLeftGlobal rect: CGRect, mainDisplayHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: mainDisplayHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    public static func display(forSelection rect: CGRect, in displays: [DisplayInfo]) -> DisplayInfo? {
        displays
            .map { (display: $0, area: area(of: rect.intersection($0.frame))) }
            .filter { $0.area > 0 }
            .max { $0.area < $1.area }?
            .display
    }

    public static func sourceRect(for selection: CGRect, on display: DisplayInfo) -> CGRect? {
        let clipped = selection.intersection(display.frame)
        guard area(of: clipped) > 0 else { return nil }
        return CGRect(
            x: clipped.minX - display.frame.minX,
            y: display.frame.maxY - clipped.maxY,
            width: clipped.width,
            height: clipped.height
        )
    }

    public static func pixelSize(of rect: CGRect, scale: CGFloat) -> (width: Int, height: Int) {
        (Int((rect.width * scale).rounded()), Int((rect.height * scale).rounded()))
    }

    /// Same rounding as `pixelSize`, so a crop from a frozen grab matches a fresh capture of the selection.
    public static func pixelRect(of sourceRect: CGRect, on display: DisplayInfo) -> CGRect {
        let size = pixelSize(of: sourceRect, scale: display.scale)
        return CGRect(
            x: (sourceRect.minX * display.scale).rounded(),
            y: (sourceRect.minY * display.scale).rounded(),
            width: CGFloat(size.width),
            height: CGFloat(size.height)
        )
    }

    private static func squaredDistance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }

    private static func area(of rect: CGRect) -> CGFloat {
        rect.isNull ? 0 : rect.width * rect.height
    }
}
