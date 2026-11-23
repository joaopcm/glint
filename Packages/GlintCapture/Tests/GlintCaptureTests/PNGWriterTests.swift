import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import GlintCapture

@Test func writesPNGWithSamePixelSize() throws {
    let img = makeSolidImage(width: 30, height: 20)
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".png")
    defer { try? FileManager.default.removeItem(at: url) }
    try PNGWriter.write(img, to: url)
    let src = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    let props = try #require(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
    #expect(props[kCGImagePropertyPixelWidth] as? Int == 30)
    #expect(props[kCGImagePropertyPixelHeight] as? Int == 20)
}

@Test func writeFailsWithPath() throws {
    let url = URL(filePath: "/nonexistent-\(UUID())/x.png")
    let error = try #require(throws: CaptureError.self) { try PNGWriter.write(makeSolidImage(width: 1, height: 1), to: url) }
    guard case .writeFailed(let path, _) = error else { Issue.record("wrong case: \(error)"); return }
    #expect(path == url.path)
    #expect(error.errorDescription?.contains(url.path) == true)
}

private func makeSolidImage(width: Int, height: Int) -> CGImage {
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(red: 1, green: 0.4, blue: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}
