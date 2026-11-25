import AppKit
import CoreGraphics
import CoreImage

@MainActor
final class AnnotationRenderCache {
    struct Key: Hashable {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
        let isBlur: Bool
        let sizeSixteenths: Int
    }

    let base: CGImage
    lazy var ciBase = CIImage(cgImage: base)
    private var patches: [Key: CGImage] = [:]
    private var order: [Key] = []
    private static let maxPatches = 32

    init(base: CGImage) {
        self.base = base
    }

    func patch(for key: Key, render: () -> CGImage?) -> CGImage? {
        if let cached = patches[key] {
            return cached
        }
        guard let rendered = render() else { return nil }
        if patches.count >= Self.maxPatches, let oldest = order.first {
            order.removeFirst()
            patches.removeValue(forKey: oldest)
        }
        patches[key] = rendered
        order.append(key)
        return rendered
    }
}

@MainActor
public enum AnnotationRenderer {
    static let ink = CGColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 1)
    static let highlight = CGColor(srgbRed: 1, green: 0.84, blue: 0, alpha: 0.45)
    private static let inkColor = NSColor(cgColor: ink)!
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let boldLineHeightRatio: CGFloat = {
        let reference: CGFloat = 100
        return NSLayoutManager().defaultLineHeight(for: .boldSystemFont(ofSize: reference)) / reference
    }()

    public static func flatten(_ base: CGImage, _ annotations: [Annotation]) -> CGImage? {
        flatten(base, annotations, crop: nil, cache: nil)
    }

    static func flatten(
        _ base: CGImage,
        _ annotations: [Annotation],
        crop: CGRect?,
        cache: AnnotationRenderCache?
    ) -> CGImage? {
        let fullRect = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        let targetRect = crop ?? fullRect
        let outWidth = Int(targetRect.width)
        let outHeight = Int(targetRect.height)
        guard outWidth > 0, outHeight > 0,
              let source = crop == nil ? base : base.cropping(to: targetRect),
              let context = CGContext(
                  data: nil, width: outWidth, height: outHeight, bitsPerComponent: 8, bytesPerRow: 0,
                  space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.draw(source, in: CGRect(x: 0, y: 0, width: outWidth, height: outHeight))
        context.translateBy(x: 0, y: CGFloat(outHeight))
        context.scaleBy(x: 1, y: -1)
        if crop != nil {
            context.translateBy(x: -targetRect.minX, y: -targetRect.minY)
        }
        draw(annotations, over: base, inFlippedContext: context, visibleRect: crop, cache: cache)
        return context.makeImage()
    }

    public static func draw(_ annotations: [Annotation], over base: CGImage, inFlippedContext context: CGContext) {
        draw(annotations, over: base, inFlippedContext: context, visibleRect: nil, cache: nil)
    }

    static func draw(
        _ annotations: [Annotation],
        over base: CGImage,
        inFlippedContext context: CGContext,
        visibleRect: CGRect? = nil,
        cache: AnnotationRenderCache? = nil
    ) {
        for annotation in annotations {
            if let visibleRect {
                let margin = max(annotation.lineWidth * 3, 2)
                guard annotation.bounds.insetBy(dx: -margin, dy: -margin).intersects(visibleRect) else { continue }
            }
            context.saveGState()
            draw(annotation, over: base, in: context, cache: cache)
            context.restoreGState()
        }
    }

    static func textFont(fittingLineHeight height: CGFloat) -> NSFont {
        .boldSystemFont(ofSize: max(height / boldLineHeightRatio, 1))
    }

    static func textSize(_ text: String, lineHeight: CGFloat) -> CGSize {
        let size = NSAttributedString(string: text, attributes: [.font: textFont(fittingLineHeight: lineHeight)]).size()
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }

    private static func draw(_ annotation: Annotation, over base: CGImage, in context: CGContext, cache: AnnotationRenderCache?) {
        switch annotation.kind {
        case .rectangle:
            context.setStrokeColor(ink)
            context.setLineWidth(annotation.lineWidth)
            context.setLineJoin(.round)
            context.stroke(annotation.bounds)
        case .highlighter:
            context.setBlendMode(.multiply)
            context.setFillColor(highlight)
            context.fill(annotation.bounds)
        case .arrow:
            drawArrow(annotation, in: context)
        case .text(let text):
            drawText(text, in: annotation.bounds, context: context)
        case .blur:
            let sigma = obscuringSize(annotation)
            obscure(annotation, of: base, isBlur: true, size: sigma, cache: cache, in: context) { region in
                blurred(base, region, sigma: sigma, cache: cache)
            }
        case .pixelate:
            context.interpolationQuality = .none
            let block = obscuringSize(annotation)
            obscure(annotation, of: base, isBlur: false, size: block, cache: cache, in: context) { region in
                pixelated(base, region, block: block)
            }
        }
    }

    // 4 strokes is 12 pt: just under the 13 pt system font (`NSFont.systemFontSize`), so a glyph turns into one smear or one block.
    private static func obscuringSize(_ annotation: Annotation) -> CGFloat {
        annotation.lineWidth * 4
    }

    private static let imageContext = CIContext(options: [.cacheIntermediates: false])

    private static func obscure(
        _ annotation: Annotation,
        of base: CGImage,
        isBlur: Bool,
        size: CGFloat,
        cache: AnnotationRenderCache?,
        in context: CGContext,
        using render: (CGRect) -> CGImage?
    ) {
        let region = annotation.bounds.integral.intersection(CGRect(x: 0, y: 0, width: base.width, height: base.height))
        guard !region.isEmpty else { return }
        let patch: CGImage?
        if let cache {
            let key = AnnotationRenderCache.Key(
                x: Int(region.minX), y: Int(region.minY),
                width: Int(region.width), height: Int(region.height),
                isBlur: isBlur, sizeSixteenths: Int((size * 16).rounded())
            )
            patch = cache.patch(for: key) { render(region) }
        } else {
            patch = render(region)
        }
        guard let patch else { return }
        context.translateBy(x: 0, y: region.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(patch, in: CGRect(x: region.minX, y: 0, width: region.width, height: region.height))
    }

    private static func blurred(_ base: CGImage, _ region: CGRect, sigma: CGFloat, cache: AnnotationRenderCache?) -> CGImage? {
        let flipped = CGRect(x: region.minX, y: CGFloat(base.height) - region.maxY, width: region.width, height: region.height)
        let source = cache?.ciBase ?? CIImage(cgImage: base)
        let output = source.cropped(to: flipped).clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: flipped)
        return imageContext.createCGImage(output, from: flipped)
    }

    private static func pixelated(_ base: CGImage, _ region: CGRect, block: CGFloat) -> CGImage? {
        let width = max(Int((region.width / block).rounded(.up)), 1)
        let height = max(Int((region.height / block).rounded(.up)), 1)
        guard let patch = base.cropping(to: region),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.interpolationQuality = .high
        context.draw(patch, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func drawArrow(_ arrow: Annotation, in context: CGContext) {
        let length = hypot(arrow.end.x - arrow.start.x, arrow.end.y - arrow.start.y)
        guard length > 0 else { return }
        let headLength = min(arrow.lineWidth * 4, length)
        let headHalfWidth = arrow.lineWidth * 2.5
        let ux = (arrow.end.x - arrow.start.x) / length, uy = (arrow.end.y - arrow.start.y) / length
        let base = CGPoint(x: arrow.end.x - ux * headLength, y: arrow.end.y - uy * headLength)

        context.setStrokeColor(ink)
        context.setFillColor(ink)
        context.setLineWidth(arrow.lineWidth)
        context.setLineCap(.round)
        context.move(to: arrow.start)
        context.addLine(to: base)
        context.strokePath()

        context.move(to: arrow.end)
        context.addLine(to: CGPoint(x: base.x - uy * headHalfWidth, y: base.y + ux * headHalfWidth))
        context.addLine(to: CGPoint(x: base.x + uy * headHalfWidth, y: base.y - ux * headHalfWidth))
        context.closePath()
        context.fillPath()
    }

    static func lineCount(_ text: String) -> Int {
        var lines = 1
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if (v >= 0x0A && v <= 0x0D) || v == 0x85 || v == 0x2028 || v == 0x2029 {
                lines += 1
            }
        }
        return lines
    }

    private static func drawText(_ text: String, in box: CGRect, context: CGContext) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: textFont(fittingLineHeight: box.height / CGFloat(lineCount(text))),
            .foregroundColor: inkColor,
        ]
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        NSAttributedString(string: text, attributes: attributes).draw(at: box.origin)
        NSGraphicsContext.restoreGraphicsState()
    }
}

extension Annotation {
    @MainActor
    public static func text(_ text: String, at origin: CGPoint, lineHeight: CGFloat, id: UUID = UUID()) -> Annotation {
        let size = AnnotationRenderer.textSize(text, lineHeight: lineHeight)
        let height = lineHeight * CGFloat(AnnotationRenderer.lineCount(text))
        return Annotation(id: id, kind: .text(text), start: origin, end: CGPoint(x: origin.x + size.width, y: origin.y + height), lineWidth: 0)
    }
}
