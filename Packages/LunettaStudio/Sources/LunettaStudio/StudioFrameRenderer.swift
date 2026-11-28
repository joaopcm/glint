import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import LunettaCore
import Synchronization

public final class StudioFrameRenderer: Sendable {
    private static let macOSDefaultAccent = CIColor(red: 0, green: 122 / 255, blue: 1)
    private static let edgeSoftness: CGFloat = 1

    private let project: RecordingProject
    private let logs: [CaptureEventLog]
    private let cursors: CursorImageLibrary
    private let sourceSize: PixelSize
    private let outputSize: PixelSize
    private let clickTint: CIColor
    private let keyCapsules = Mutex<[String: KeyCapsule]>([:])

    public init(project: RecordingProject, logs: [CaptureEventLog], cursors: CursorImageLibrary, sourceSize: PixelSize, outputSize: PixelSize) {
        precondition(
            logs.count == project.parts.count,
            "A renderer needs one event log per part: the project has \(project.parts.count) parts, got \(logs.count) logs."
        )
        self.project = project
        self.logs = logs
        self.cursors = cursors
        self.sourceSize = sourceSize
        self.outputSize = outputSize
        clickTint = SRGBColor(hex: project.overlays.clickColorHex).map { CIColor(red: $0.red, green: $0.green, blue: $0.blue) } ?? Self.macOSDefaultAccent
    }

    public func frame(screen: CIImage, camera: CIImage?, part: Int, hostTime: Double) -> CIImage {
        let log = logs[part]
        let canvas = Canvas(region: region(in: log, at: hostTime), source: sourceSize, output: outputSize)
        var layers: [CIImage] = []
        if project.overlays.clicks { layers += clickRings(in: log, at: hostTime, on: canvas) }
        if project.overlays.keys, let keys = keysCapsule(in: log, at: hostTime, on: canvas) { layers.append(keys) }
        if project.overlays.camera, let camera, let frame = log.bubbleFrame(at: hostTime), let bubble = bubble(camera, in: frame, on: canvas) {
            layers.append(bubble)
        }
        if let cursor = cursor(in: log, at: hostTime, on: canvas) { layers.append(cursor) }
        return layers
            .reduce(screen.transformed(by: canvas.sourceToOutput)) { $1.composited(over: $0) }
            .cropped(to: canvas.outputBounds)
    }

    private func region(in log: CaptureEventLog, at t: Double) -> CGRect {
        switch project.mode {
        case .area: project.region
        case .window: log.windowFrame(at: t) ?? project.region
        }
    }

    private func clickRings(in log: CaptureEventLog, at t: Double, on canvas: Canvas) -> [CIImage] {
        log.clicks(in: (t - OverlayStyle.clickPulseDuration)...t)
            .filter { canvas.region.contains($0.point) }
            .map { click in
                let eased = EaseOut.value(at: (t - click.t) / OverlayStyle.clickPulseDuration)
                let scale = OverlayStyle.clickStartScale + (1 - OverlayStyle.clickStartScale) * eased
                return Self.disc(
                    at: canvas.point(click.point),
                    radius: canvas.length(OverlayStyle.clickDiameter * scale / 2),
                    color: Self.color(clickTint, alpha: OverlayStyle.clickFillAlpha * (1 - eased))
                )
            }
    }

    private func keysCapsule(in log: CaptureEventLog, at t: Double, on canvas: Canvas) -> CIImage? {
        guard let key = log.key(at: t) else { return nil }
        let capsule = keysCapsuleImage(key.label, pixelsPerPoint: canvas.length(1))
        let bottomCenter = canvas.point(CGPoint(x: canvas.region.midX, y: canvas.region.minY + OverlayStyle.keysBottomInset))
        let placed = capsule.transformed(by: CGAffineTransform(
            translationX: (bottomCenter.x - capsule.extent.width / 2).rounded(),
            y: bottomCenter.y.rounded()
        ))
        let fadingFor = key.age - OverlayStyle.keysLinger
        guard fadingFor > 0 else { return placed }
        let opacity = max(0, 1 - fadingFor / OverlayStyle.exitDuration)
        return placed.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)])
    }

    private func keysCapsuleImage(_ label: String, pixelsPerPoint: CGFloat) -> CIImage {
        if let cached = keyCapsules.withLock({ $0[label] }), cached.pixelsPerPoint == pixelsPerPoint { return cached.image }
        let image = Self.drawKeysCapsule(label, pixelsPerPoint: pixelsPerPoint)
        keyCapsules.withLock { $0[label] = KeyCapsule(pixelsPerPoint: pixelsPerPoint, image: image) }
        return image
    }

    private func bubble(_ camera: CIImage, in frame: CGRect, on canvas: Canvas) -> CIImage? {
        let video = camera.extent
        guard !video.isEmpty, !video.isInfinite else { return nil }
        let bounds = canvas.rect(frame)
        let fill = max(bounds.width / video.width, bounds.height / video.height)
        let filled = camera.transformed(by: CGAffineTransform(translationX: -video.midX, y: -video.midY)
            .concatenating(CGAffineTransform(scaleX: project.overlays.cameraMirrored ? -fill : fill, y: fill))
            .concatenating(CGAffineTransform(translationX: bounds.midX, y: bounds.midY)))
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = min(bounds.width, bounds.height) / 2
        let white = CIColor(red: 1, green: 1, blue: 1)
        let circle = filled.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: Self.disc(at: center, radius: radius, color: white),
        ])
        let inside = Self.disc(at: center, radius: radius - canvas.length(OverlayStyle.bubbleBorderWidth), color: white)
        let border = Self.disc(at: center, radius: radius, color: Self.color(white, alpha: OverlayStyle.bubbleBorderAlpha))
            .applyingFilter("CISourceOutCompositing", parameters: [kCIInputBackgroundImageKey: inside])
        return border.composited(over: circle)
    }

    private func cursor(in log: CaptureEventLog, at t: Double, on canvas: Canvas) -> CIImage? {
        guard let pointer = log.pointer(at: t), let shape = log.cursor(at: t), let image = cursors.image(named: shape.image) else { return nil }
        if project.mode == .window, !canvas.region.contains(pointer) { return nil }
        let scale = canvas.length(1)
        let tip = canvas.point(pointer)
        let top = tip.y + shape.hotspot.y * scale
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale).concatenating(CGAffineTransform(
            translationX: tip.x - shape.hotspot.x * scale,
            y: top - image.extent.height * scale
        )))
    }

    private static func disc(at center: CGPoint, radius: CGFloat, color: CIColor) -> CIImage {
        let gradient = CIFilter.radialGradient()
        gradient.center = center
        gradient.radius0 = Float(max(0, radius - edgeSoftness / 2))
        gradient.radius1 = Float(max(0, radius + edgeSoftness / 2))
        gradient.color0 = color
        gradient.color1 = Self.color(color, alpha: 0)
        let reach = radius + edgeSoftness
        return gradient.outputImage?.cropped(to: CGRect(x: center.x - reach, y: center.y - reach, width: reach * 2, height: reach * 2)) ?? .empty()
    }

    private static func drawKeysCapsule(_ label: String, pixelsPerPoint scale: CGFloat) -> CIImage {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): keysFont(size: OverlayStyle.keysFontSize * scale),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        ]))
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        let size = CGSize(
            width: (textWidth + OverlayStyle.keysHorizontalPadding * scale).rounded(.up),
            height: (OverlayStyle.keysHeight * scale).rounded(.up)
        )
        guard let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return .empty() }
        let corner = OverlayStyle.keysCornerRadius * scale
        context.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: corner, cornerHeight: corner, transform: nil))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: OverlayStyle.keysBackgroundAlpha))
        context.fillPath()
        context.textPosition = CGPoint(x: (size.width - textWidth) / 2, y: (size.height - ascent - descent) / 2 + descent)
        CTLineDraw(line, context)
        return context.makeImage().map { CIImage(cgImage: $0) } ?? .empty()
    }

    /// Core Text has no public way to ask for the system font's rounded design; AppKit's font descriptor has one.
    private static func keysFont(size: CGFloat) -> CTFont {
        let base = NSFont.systemFont(ofSize: size, weight: .semibold)
        let rounded = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        return rounded as CTFont
    }

    private static func color(_ color: CIColor, alpha: Double) -> CIColor {
        CIColor(red: color.red, green: color.green, blue: color.blue, alpha: alpha)
    }
}

private struct KeyCapsule {
    let pixelsPerPoint: CGFloat
    let image: CIImage
}

private struct Canvas {
    let region: CGRect
    let sourceToOutput: CGAffineTransform
    let outputBounds: CGRect
    private let pixelsPerPoint: (x: CGFloat, y: CGFloat)

    init(region: CGRect, source: PixelSize, output: PixelSize) {
        self.region = region
        let sourcePerPoint = CGFloat(source.width) / region.width
        let outputPerSource = (x: CGFloat(output.width) / CGFloat(source.width), y: CGFloat(output.height) / CGFloat(source.height))
        sourceToOutput = CGAffineTransform(scaleX: outputPerSource.x, y: outputPerSource.y)
        outputBounds = CGRect(x: 0, y: 0, width: output.width, height: output.height)
        pixelsPerPoint = (sourcePerPoint * outputPerSource.x, sourcePerPoint * outputPerSource.y)
    }

    func point(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - region.minX) * pixelsPerPoint.x, y: (point.y - region.minY) * pixelsPerPoint.y)
    }

    func rect(_ rect: CGRect) -> CGRect {
        CGRect(origin: point(rect.origin), size: CGSize(width: rect.width * pixelsPerPoint.x, height: rect.height * pixelsPerPoint.y))
    }

    func length(_ points: Double) -> CGFloat {
        points * pixelsPerPoint.x
    }
}

/// `OverlayStyle.easeOutControlPoints` as a cubic Bézier, the curve Core Animation runs the on-screen overlays on.
private enum EaseOut {
    static func value(at progress: Double) -> Double {
        let (x1, y1, x2, y2) = OverlayStyle.easeOutControlPoints
        var low = 0.0
        var high = 1.0
        while true {
            let mid = (low + high) / 2
            guard mid > low, mid < high else { return curve(mid, y1, y2) }
            if curve(mid, x1, x2) < progress { low = mid } else { high = mid }
        }
    }

    private static func curve(_ s: Double, _ p1: Double, _ p2: Double) -> Double {
        let rest = 1 - s
        return 3 * rest * rest * s * p1 + 3 * rest * s * s * p2 + s * s * s
    }
}
