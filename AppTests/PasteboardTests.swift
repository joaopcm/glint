import AppKit
import Testing
@testable import Glint

@MainActor @Test func copyPNGFilePutsFileURLAndPNGOnThePasteboard() throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 30, pixelsHigh: 20, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let url = FileManager.default.temporaryDirectory.appending(path: "glint-pasteboard-\(UUID().uuidString).png")
    let png = try #require(rep.representation(using: .png, properties: [:]))
    try png.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }

    try pasteboard.copyPNGFile(at: url)

    #expect(pasteboard.string(forType: .fileURL) == url.absoluteString)
    #expect(pasteboard.data(forType: .png) == png)
}

@MainActor @Test func copyTextPutsPlainTextOnThePasteboard() throws {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }

    try pasteboard.copyText("one\ntwo")

    #expect(pasteboard.string(forType: .string) == "one\ntwo")
    #expect(pasteboard.data(forType: .png) == nil)
}
