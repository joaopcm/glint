import AppKit
import CoreGraphics

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
        draw(annotations, inFlippedContext: context)
        return context.makeImage()
    }

    public static func draw(_ annotations: [Annotation], inFlippedContext context: CGContext) {
        for annotation in annotations {
            context.saveGState()
            draw(annotation, in: context)
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

    private static func draw(_ annotation: Annotation, in context: CGContext) {
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
        }
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
