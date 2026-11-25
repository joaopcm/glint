import CoreGraphics
import Foundation
import Testing
@testable import GlintEditor

@MainActor
struct ObscureAndCropTests {
    let stripes = stripedImage(width: 200, height: 100)
    let region = CGRect(x: 40, y: 20, width: 80, height: 60)

    @Test(arguments: [Annotation.Kind.blur, .pixelate])
    func obscuredPixelsDoNotMatchTheOriginal(kind: Annotation.Kind) throws {
        let layer = Annotation(kind: kind, start: region.origin, end: CGPoint(x: region.maxX, y: region.maxY), lineWidth: 6)
        let original = Pixels(stripes)
        let flat = try Pixels(#require(AnnotationRenderer.flatten(stripes, [layer])))
        #expect(flat.matchingShare(original, in: region) < 0.1)
        #expect(flat.matchingShare(original, in: CGRect(x: 150, y: 0, width: 50, height: 100)) == 1)
    }

    @Test(arguments: [Annotation.Kind.blur, .pixelate])
    func obscuringRendersFromTheBaseNotFromLayersBelow(kind: Annotation.Kind) throws {
        let ink = Annotation(kind: .highlighter, start: region.origin, end: CGPoint(x: region.maxX, y: region.maxY), lineWidth: 6)
        let layer = Annotation(kind: kind, start: region.origin, end: CGPoint(x: region.maxX, y: region.maxY), lineWidth: 6)
        let withInk = try Pixels(#require(AnnotationRenderer.flatten(stripes, [ink, layer])))
        let without = try Pixels(#require(AnnotationRenderer.flatten(stripes, [layer])))
        #expect(withInk.matchingShare(without, in: region) == 1)
    }

    @Test func movingABlurLeavesTheOldSpotUntouchedAndBlursTheNewOne() throws {
        let document = AnnotationDocument(base: stripes)
        let layer = Annotation(kind: .blur, start: region.origin, end: CGPoint(x: region.maxX, y: region.maxY), lineWidth: 6)
        document.add(layer)
        document.move(layer.id, by: CGSize(width: 70, height: 0))
        let original = Pixels(stripes)
        let flat = try Pixels(#require(document.flattened()))
        #expect(flat.matchingShare(original, in: CGRect(x: 40, y: 20, width: 60, height: 60)) == 1)
        #expect(flat.matchingShare(original, in: CGRect(x: 120, y: 20, width: 70, height: 60)) < 0.1)
    }

    @Test func cropExportsExactlyTheCroppedPixelSize() throws {
        let document = AnnotationDocument(base: stripes)
        document.setCrop(CGRect(x: 10, y: 20, width: 50, height: 30))
        let flat = try #require(document.flattened())
        #expect((flat.width, flat.height) == (50, 30))
    }

    @Test func cropKeepsTheCroppedPixelsAndAnnotations() throws {
        let document = AnnotationDocument(base: solidImage(width: 200, height: 100))
        document.add(Annotation(kind: .rectangle, start: CGPoint(x: 20, y: 20), end: CGPoint(x: 80, y: 60), lineWidth: 4))
        document.setCrop(CGRect(x: 10, y: 10, width: 100, height: 60))
        let flat = try Pixels(#require(document.flattened()))
        #expect(flat.isInk(x: 10, y: 20), "the rectangle's left edge, 10 px into the crop")
        #expect(flat.isWhite(x: 40, y: 30))
    }

    @Test func fractionalCropGrowsToWholePixelsInsideTheImage() {
        let document = AnnotationDocument(base: stripes)
        document.setCrop(CGRect(x: 150.5, y: -10, width: 80, height: 50.2))
        #expect(document.crop == CGRect(x: 150, y: 0, width: 50, height: 41))
    }

    @Test func cropIsNonDestructiveAndUndoable() throws {
        let document = AnnotationDocument(base: stripes)
        document.setCrop(CGRect(x: 10, y: 20, width: 50, height: 30))
        #expect(document.base.width == 200)
        #expect(document.undoManager.undoActionName == "Crop")
        document.undoManager.undo()
        #expect(document.crop == nil)
        #expect(try #require(document.flattened()).width == 200)
        document.undoManager.redo()
        #expect(document.crop == CGRect(x: 10, y: 20, width: 50, height: 30))
    }

    @Test func cropToTheWholeImageOrNothingRemovesIt() {
        let document = AnnotationDocument(base: stripes)
        document.setCrop(CGRect(x: 10, y: 20, width: 50, height: 30))
        document.setCrop(CGRect(x: 0, y: 0, width: 200, height: 100))
        #expect(document.crop == nil)
        document.setCrop(CGRect(x: 300, y: 300, width: 10, height: 10))
        #expect(document.crop == nil)
    }

    @Test func blurAndPixelateUndoLikeTheOtherTools() {
        let document = AnnotationDocument(base: stripes)
        document.add(Annotation(kind: .pixelate, start: .zero, end: CGPoint(x: 10, y: 10), lineWidth: 6))
        #expect(document.undoManager.undoActionName == "Add Pixelate")
        document.undoManager.undo()
        #expect(document.annotations.isEmpty)
    }

    @Test func croppedFlattenMatchesFullFlattenThenCropWithObscureAndInk() throws {
        let crop = CGRect(x: 30, y: 15, width: 90, height: 65)
        let annotations = [
            Annotation(kind: .blur, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 70, y: 60), lineWidth: 6),
            Annotation(kind: .pixelate, start: CGPoint(x: 60, y: 30), end: CGPoint(x: 110, y: 75), lineWidth: 6),
            Annotation(kind: .arrow, start: CGPoint(x: 20, y: 20), end: CGPoint(x: 100, y: 70), lineWidth: 4),
            Annotation(kind: .rectangle, start: CGPoint(x: 150, y: 10), end: CGPoint(x: 190, y: 90), lineWidth: 4),
        ]
        let document = AnnotationDocument(base: stripes)
        annotations.forEach(document.add)
        document.setCrop(crop)

        let direct = try Pixels(#require(document.flattened()))
        let reference = try Pixels(#require(AnnotationRenderer.flatten(stripes, annotations)?.cropping(to: crop)))
        #expect(direct.matchingShare(reference, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height)) == 1)
    }
}

extension Pixels {
    func matchingShare(_ other: Pixels, in rect: CGRect) -> Double {
        var matching = 0, total = 0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                let a = rgb(x: x, y: y), b = other.rgb(x: x, y: y)
                if abs(a.r - b.r) <= 8, abs(a.g - b.g) <= 8, abs(a.b - b.b) <= 8 { matching += 1 }
                total += 1
            }
        }
        return Double(matching) / Double(total)
    }
}

func stripedImage(width: Int, height: Int) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    for x in 0..<width {
        let value: CGFloat = x % 2 == 0 ? 0 : 1
        context.setFillColor(red: value, green: value, blue: value, alpha: 1)
        context.fill(CGRect(x: x, y: 0, width: 1, height: height))
    }
    return context.makeImage()!
}
