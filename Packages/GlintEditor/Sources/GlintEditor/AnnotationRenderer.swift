import AppKit
import CoreGraphics
import CoreImage

@MainActor
public enum AnnotationRenderer {
    static let ink = CGColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 1)
    static let highlight = CGColor(srgbRed: 1, green: 0.84, blue: 0, alpha: 0.45)

    public static func flatten(_ base: CGImage, _ annotations: [Annotation]) -> CGImage? {
        let rect = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        guard let context = CGContext(
            data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(base, in: rect)
        context.translateBy(x: 0, y: rect.height)
        context.scaleBy(x: 1, y: -1)
        draw(annotations, over: base, inFlippedContext: context)
        return context.makeImage()
    }

    public static func draw(_ annotations: [Annotation], over base: CGImage, inFlippedContext context: CGContext) {
        for annotation in annotations {
            context.saveGState()
            draw(annotation, over: base, in: context)
            context.restoreGState()
        }
    }

    static func textFont(fittingLineHeight height: CGFloat) -> NSFont {
        let reference: CGFloat = 100
        let lineHeight = NSLayoutManager().defaultLineHeight(for: .boldSystemFont(ofSize: reference)) / reference
        return .boldSystemFont(ofSize: max(height / lineHeight, 1))
    }

    static func textSize(_ text: String, lineHeight: CGFloat) -> CGSize {
        let size = NSAttributedString(string: text, attributes: [.font: textFont(fittingLineHeight: lineHeight)]).size()
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }

    private static func draw(_ annotation: Annotation, over base: CGImage, in context: CGContext) {
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
            obscure(annotation, of: base, in: context) { region in blurred(base, region, sigma: obscuringSize(annotation)) }
        case .pixelate:
            context.interpolationQuality = .none
            obscure(annotation, of: base, in: context) { region in pixelated(base, region, block: obscuringSize(annotation)) }
        }
    }

    // 4 strokes is 12 pt: just under the 13 pt system font (`NSFont.systemFontSize`), so a glyph turns into one smear or one block.
    private static func obscuringSize(_ annotation: Annotation) -> CGFloat {
        annotation.lineWidth * 4
    }

    private static let imageContext = CIContext(options: [.cacheIntermediates: false])

    private static func obscure(_ annotation: Annotation, of base: CGImage, in context: CGContext, using render: (CGRect) -> CGImage?) {
        let region = annotation.bounds.integral.intersection(CGRect(x: 0, y: 0, width: base.width, height: base.height))
        guard !region.isEmpty, let patch = render(region) else { return }
        context.translateBy(x: 0, y: region.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(patch, in: CGRect(x: region.minX, y: 0, width: region.width, height: region.height))
    }

    private static func blurred(_ base: CGImage, _ region: CGRect, sigma: CGFloat) -> CGImage? {
        let flipped = CGRect(x: region.minX, y: CGFloat(base.height) - region.maxY, width: region.width, height: region.height)
        let output = CIImage(cgImage: base).cropped(to: flipped).clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: flipped)
        return imageContext.createCGImage(output, from: flipped)
    }

    private static func pixelated(_ base: CGImage, _ region: CGRect, block: CGFloat) -> CGImage? {
        let width = max(Int((region.width / block).rounded(.up)), 1)
        let height = max(Int((region.height / block).rounded(.up)), 1)
        guard let patch = base.cropping(to: region),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
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
        text.components(separatedBy: .newlines).count
    }

    private static func drawText(_ text: String, in box: CGRect, context: CGContext) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: textFont(fittingLineHeight: box.height / CGFloat(lineCount(text))),
            .foregroundColor: NSColor(cgColor: ink)!,
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
