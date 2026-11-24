import CoreGraphics
import Foundation
import Testing
@testable import GlintEditor

@MainActor
struct AnnotationRendererTests {
    let base = solidImage(width: 200, height: 100)

    @Test func keepsThePixelSize() throws {
        let flat = try #require(AnnotationRenderer.flatten(base, []))
        #expect(flat.width == 200)
        #expect(flat.height == 100)
    }

    @Test func rectangleStrokesTheEdgeOnly() throws {
        let box = Annotation(kind: .rectangle, start: CGPoint(x: 20, y: 20), end: CGPoint(x: 80, y: 60), lineWidth: 4)
        let pixels = try Pixels(#require(AnnotationRenderer.flatten(base, [box])))
        #expect(pixels.isInk(x: 20, y: 40))
        #expect(pixels.isInk(x: 50, y: 20))
        #expect(pixels.isWhite(x: 50, y: 40))
        #expect(pixels.isWhite(x: 150, y: 80))
    }

    @Test func topLeftOriginMatchesTheImageRows() throws {
        let box = Annotation(kind: .highlighter, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 200, y: 10), lineWidth: 4)
        let pixels = try Pixels(#require(AnnotationRenderer.flatten(base, [box])))
        #expect(!pixels.isWhite(x: 100, y: 5))
        #expect(pixels.isWhite(x: 100, y: 95))
    }

    @Test func highlighterTintsWithoutHidingTheImage() throws {
        let mark = Annotation(kind: .highlighter, start: CGPoint(x: 100, y: 10), end: CGPoint(x: 190, y: 90), lineWidth: 4)
        let pixels = try Pixels(#require(AnnotationRenderer.flatten(base, [mark])))
        let tinted = pixels.rgb(x: 150, y: 50)
        #expect(tinted.r > 240 && tinted.g > 200 && tinted.b < 200)
        #expect(pixels.isWhite(x: 50, y: 50))
    }

    @Test func arrowDrawsTheShaftAndHead() throws {
        let arrow = Annotation(kind: .arrow, start: CGPoint(x: 10, y: 50), end: CGPoint(x: 190, y: 50), lineWidth: 4)
        let pixels = try Pixels(#require(AnnotationRenderer.flatten(base, [arrow])))
        #expect(pixels.isInk(x: 60, y: 50))
        #expect(pixels.isInk(x: 180, y: 50))
        #expect(pixels.isInk(x: 178, y: 56), "the head is wider than the shaft")
        #expect(pixels.isWhite(x: 60, y: 60))
    }

    @Test func textDrawsInsideItsBox() throws {
        let label = Annotation(kind: .text("HI"), start: CGPoint(x: 20, y: 20), end: CGPoint(x: 120, y: 60), lineWidth: 4)
        let pixels = try Pixels(#require(AnnotationRenderer.flatten(base, [label])))
        let inside = pixels.inkCount(in: CGRect(x: 20, y: 20, width: 100, height: 40))
        let outside = pixels.inkCount(in: CGRect(x: 0, y: 0, width: 200, height: 100)) - inside
        #expect(inside > 100)
        #expect(outside == 0)
    }

    @Test func laterAnnotationsDrawOnTop() throws {
        let under = Annotation(kind: .highlighter, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 100), lineWidth: 4)
        let over = Annotation(kind: .rectangle, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 50, y: 50), lineWidth: 6)
        let pixels = try Pixels(#require(AnnotationRenderer.flatten(base, [under, over])))
        #expect(pixels.isInk(x: 10, y: 30))
    }
}

struct Pixels {
    let bytes: [UInt8]
    let width: Int

    init(_ image: CGImage) {
        width = image.width
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(
            data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        self.bytes = bytes
    }

    func rgb(x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        let i = (y * width + x) * 4
        return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
    }

    func isWhite(x: Int, y: Int) -> Bool {
        let p = rgb(x: x, y: y)
        return p.r > 250 && p.g > 250 && p.b > 250
    }

    func isInk(x: Int, y: Int) -> Bool {
        let p = rgb(x: x, y: y)
        return p.r > 200 && p.g < 120 && p.b < 120
    }

    func inkCount(in rect: CGRect) -> Int {
        var count = 0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) where isInk(x: x, y: y) {
                count += 1
            }
        }
        return count
    }
}

func solidImage(width: Int, height: Int) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}
