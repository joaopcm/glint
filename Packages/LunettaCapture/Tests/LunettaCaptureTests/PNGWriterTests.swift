import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import LunettaCapture

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

@Test func missingFolderReasonIsThePOSIXError() throws {
    let url = URL(filePath: "/nonexistent-\(UUID())/x.png")
    let error = try #require(throws: CaptureError.self) { try PNGWriter.write(makeSolidImage(width: 1, height: 1), to: url) }
    #expect(error == .writeFailed(path: url.path, underlying: String(cString: strerror(ENOENT))))
}

@Test func readOnlyFolderReasonIsThePOSIXError() throws {
    let folder = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
    let url = folder.appending(path: "x.png")
    let error = try #require(throws: CaptureError.self) { try PNGWriter.write(makeSolidImage(width: 1, height: 1), to: url) }
    #expect(error == .writeFailed(path: url.path, underlying: String(cString: strerror(EACCES))))
}

@Test func failedWriteLeavesNoFileBehind() throws {
    let folder = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appending(path: "x.png")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    let error = try #require(throws: CaptureError.self) { try PNGWriter.write(makeSolidImage(width: 30, height: 20), to: url) }
    #expect(error == .writeFailed(path: url.path, underlying: "Is a directory"))
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["x.png"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: url.path).isEmpty)
}

private func makeTemporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    return folder
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
