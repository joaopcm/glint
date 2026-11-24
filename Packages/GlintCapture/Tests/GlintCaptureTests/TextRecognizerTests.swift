import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import GlintCapture

@Test func recognizesTheFixtureLinesInReadingOrder() async throws {
    let url = try #require(Bundle.module.url(forResource: "two-lines", withExtension: "png", subdirectory: "Fixtures"))
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(try await TextRecognizer.lines(in: image) == ["Glint reads this line", "and the next one too"])
}

@Test func blankImageHasNoLines() async throws {
    let context = try #require(CGContext(
        data: nil, width: 640, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ))
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 640, height: 200))
    let image = try #require(context.makeImage())
    #expect(try await TextRecognizer.lines(in: image).isEmpty)
}
