import CoreGraphics
import Testing
@testable import Lunetta

@Test func downsamplerShrinksLargeImagesAndReturnsSmallerOnesUntouched() throws {
    let small = try solidImage(width: 400, height: 300)
    #expect(ThumbnailDownsampler.downsample(small, maxPixelSize: 960) === small)

    let large = try solidImage(width: 2000, height: 1000)
    let scaled = ThumbnailDownsampler.downsample(large, maxPixelSize: 960)
    #expect(scaled.width == 960 && scaled.height == 480)
}

@Test func tallImageThumbnailShowsTheTop() throws {
    let context = try #require(rgbaContext(width: 1600, height: 20000))
    context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 1600, height: 20000))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 20000 - 100, width: 1600, height: 100))
    let tall = try #require(context.makeImage())

    let thumbnail = ThumbnailDownsampler.downsample(tall, maxPixelSize: 960)

    #expect(thumbnail.width == 960)
    #expect(CGFloat(thumbnail.height) == ThumbnailPresenter.height(forWidth: 960).rounded())
    let topLeft = try topLeftPixel(of: thumbnail)
    #expect(topLeft.red > 200 && topLeft.blue < 50)
}

@Test func aTallVideoFrameThumbnailKeepsTheWholeFrame() throws {
    let frame = try solidImage(width: 1600, height: 20000)
    let thumbnail = ThumbnailDownsampler.downsample(frame, maxPixelSize: 960, keepsWholeFrame: true)
    #expect(thumbnail.width == 77 && thumbnail.height == 960)
}

@Test func normalImageThumbnailIsUnchanged() throws {
    let normal = try solidImage(width: 1600, height: 1000)
    let thumbnail = ThumbnailDownsampler.downsample(normal, maxPixelSize: 960)
    #expect(thumbnail.width == 960 && thumbnail.height == 600)
}

private func rgbaContext(width: Int, height: Int) -> CGContext? {
    CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
}

private func solidImage(width: Int, height: Int) throws -> CGImage {
    try #require(rgbaContext(width: width, height: height)?.makeImage())
}

private func topLeftPixel(of image: CGImage) throws -> (red: UInt8, blue: UInt8) {
    let context = try #require(rgbaContext(width: image.width, height: image.height))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
    return (pixels[0], pixels[2])
}
