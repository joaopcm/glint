import AppKit
import LunettaCapture
import LunettaCore
import Testing
@testable import Lunetta

@MainActor private final class Seen {
    var cards: [(url: URL, compression: PendingCompression)] = []
    var problems: [String] = []
}

/// Settings stay off so the timer never races the test for the copy: the tests call `checkForCopy()` themselves.
@MainActor private func makeCompressor(
    on pasteboard: NSPasteboard,
    seen: Seen,
    compress: @escaping @Sendable (URL) async throws -> CompressionResult? = CaptureCompressor.compress
) -> ClipboardCompressor {
    ClipboardCompressor(
        settings: LunettaSettings(store: Defaults(), defaultSaveFolder: FileManager.default.temporaryDirectory),
        pasteboard: pasteboard,
        scratch: FileManager.default.temporaryDirectory.appending(path: "lunetta-copied-\(UUID().uuidString)"),
        compress: compress,
        show: { seen.cards.append(($0, $1)) },
        onProblem: { seen.problems.append($0) }
    )
}

/// 200 × 200 of one color as an uncompressed TIFF, about 160 KB: what Preview and Safari put on the clipboard.
private func solidTIFF() throws -> Data {
    let context = try #require(CGContext(
        data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(red: 1, green: 0.2, blue: 0.1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
    let image = try #require(context.makeImage())
    return try #require(NSBitmapImageRep(cgImage: image).tiffRepresentation)
}

private let writeThreeBytes: @Sendable (URL) async throws -> CompressionResult? = { url in
    try Data([1, 2, 3]).write(to: url)
    return CompressionResult(originalBytes: 1000, compressedBytes: 3)
}

@MainActor private func put(_ item: NSPasteboardItem, on pasteboard: NSPasteboard) {
    pasteboard.clearContents()
    pasteboard.writeObjects([item])
}

@MainActor @Test func aCopiedImageIsCompressedAndReplacesItOnTheClipboard() async throws {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let seen = Seen()
    let compressor = makeCompressor(on: pasteboard, seen: seen)
    let tiff = try solidTIFF()
    pasteboard.clearContents()
    pasteboard.setData(tiff, forType: .tiff)

    await compressor.checkForCopy()?.value

    let card = try #require(seen.cards.first)
    let result = try #require(try await card.compression.value)
    #expect(result.originalBytes == tiff.count)
    let compressed = try Data(contentsOf: card.url)
    #expect(result.compressedBytes == compressed.count)
    #expect(compressed.count < tiff.count)
    #expect(card.url.pathExtension == "png")
    #expect(pasteboard.data(forType: .png) == compressed)
    #expect(pasteboard.string(forType: .fileURL) == card.url.absoluteString)
    #expect(compressor.checkForCopy() == nil) // what it put there is its own, so it doesn't start over on it
    #expect(seen.problems.isEmpty)
}

@MainActor @Test func aCopiedFileStaysAsItIsAndItsCompressedCopyTakesItsPlace() async throws {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let seen = Seen()
    let compressor = makeCompressor(on: pasteboard, seen: seen, compress: writeThreeBytes)
    let original = try writePNG()
    defer { try? FileManager.default.removeItem(at: original) }
    let originalBytes = try Data(contentsOf: original)
    let item = NSPasteboardItem()
    item.setString(original.absoluteString, forType: .fileURL)
    put(item, on: pasteboard)

    await compressor.checkForCopy()?.value

    let card = try #require(seen.cards.first)
    #expect(try await card.compression.value != nil)
    #expect(try Data(contentsOf: original) == originalBytes)
    #expect(card.url != original)
    #expect(card.url.lastPathComponent == original.lastPathComponent)
    #expect(pasteboard.string(forType: .fileURL) == card.url.absoluteString)
    #expect(pasteboard.data(forType: .png) == Data([1, 2, 3]))
}

@MainActor @Test func aCopyThatWouldNotShrinkLeavesTheClipboardAlone() async throws {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let seen = Seen()
    let compressor = makeCompressor(on: pasteboard, seen: seen, compress: { _ in nil })
    let png = try Data(contentsOf: try writePNG())
    pasteboard.clearContents()
    pasteboard.setData(png, forType: .png)
    let copied = pasteboard.changeCount

    await compressor.checkForCopy()?.value

    let card = try #require(seen.cards.first)
    #expect(try await card.compression.value == nil)
    #expect(pasteboard.changeCount == copied)
    #expect(pasteboard.data(forType: .png) == png)
}

@MainActor @Test func somethingCopiedWhileCompressingStaysOnTheClipboard() async throws {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let seen = Seen()
    let release = AsyncStream<Void>.makeStream()
    let compressor = makeCompressor(on: pasteboard, seen: seen) { url in
        for await _ in release.stream { break }
        return try await writeThreeBytes(url)
    }
    pasteboard.clearContents()
    pasteboard.setData(try solidTIFF(), forType: .tiff)

    let work = compressor.checkForCopy()
    pasteboard.clearContents()
    pasteboard.setString("copied while compressing", forType: .string)
    release.continuation.yield()
    await work?.value

    #expect(try await seen.cards.first?.compression.value != nil)
    #expect(pasteboard.string(forType: .string) == "copied while compressing")
    #expect(pasteboard.data(forType: .png) == nil)
}

@MainActor @Test func lunettasOwnCopiesAreLeftAlone() throws {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let seen = Seen()
    let compressor = makeCompressor(on: pasteboard, seen: seen)
    let png = try writePNG()

    try pasteboard.copyPNGFile(at: png)
    #expect(pasteboard.holdsLunettaCopy)
    #expect(compressor.checkForCopy() == nil)

    pasteboard.clearContents()
    pasteboard.setString("someone else's", forType: .string)
    #expect(!pasteboard.holdsLunettaCopy)
    #expect(seen.cards.isEmpty)
}

@MainActor @Test func onlyImagesAndRecordingsCompressionCanShrinkAreTaken() throws {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let tiff = try solidTIFF()
    let png = Data([0x89, 0x50, 0x4e, 0x47])
    func media(_ entries: [NSPasteboard.PasteboardType: Data]) -> CopiedMedia? {
        let item = NSPasteboardItem()
        for (type, data) in entries { item.setData(data, forType: type) }
        put(item, on: pasteboard)
        return CopiedMedia.on(pasteboard)
    }
    func file(_ name: String) -> URL { FileManager.default.temporaryDirectory.appending(path: name) }
    func reference(_ name: String) -> Data { Data(file(name).absoluteString.utf8) }

    #expect(media([.png: png]) == .png(png))
    #expect(media([.tiff: tiff]) == .tiff(tiff))
    #expect(media([.png: png, .html: Data("<img>".utf8)]) == .png(png)) // Chrome's Copy Image
    #expect(media([.string: Data("words".utf8)]) == nil)
    #expect(media([.tiff: tiff, .rtf: Data("{\\rtf1}".utf8)]) == nil)
    #expect(media([.tiff: tiff, .pdf: Data("%PDF".utf8)]) == nil)
    #expect(media([.png: png, .init("org.nspasteboard.ConcealedType"): Data()]) == nil)

    // Finder: the file, its name and its icon. The icon is never what was copied.
    #expect(media([.fileURL: reference("notes.txt"), .tiff: tiff]) == nil)
    #expect(media([.fileURL: reference("photo.jpg")]) == nil)
    #expect(media([.fileURL: reference("shot.png"), .tiff: tiff]) == .file(file("shot.png")))
    #expect(media([.fileURL: reference("demo.mov")]) == .file(file("demo.mov")))
}

@MainActor @Test func watchingTheClipboardFollowsTheSetting() async throws {
    let settings = LunettaSettings(store: Defaults(), defaultSaveFolder: FileManager.default.temporaryDirectory)
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let compressor = ClipboardCompressor(settings: settings, pasteboard: pasteboard, show: { _, _ in }, onProblem: { _ in })
    #expect(!compressor.isWatching)

    settings.compressCopiedMedia = true
    try await Task.sleep(for: .milliseconds(50))
    #expect(compressor.isWatching)

    settings.compressCopiedMedia = false
    try await Task.sleep(for: .milliseconds(50))
    #expect(!compressor.isWatching)
}

@MainActor private final class Input {
    var secondsSinceLast: TimeInterval = 0
    var resume: (@MainActor () -> Void)?
}

@MainActor @Test func checkingStopsWhileNobodyTouchesTheMacAndTheNextInputStartsItAgain() async throws {
    let settings = LunettaSettings(store: Defaults(), defaultSaveFolder: FileManager.default.temporaryDirectory)
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let seen = Seen()
    let input = Input()
    let compressor = ClipboardCompressor(
        settings: settings,
        pasteboard: pasteboard,
        scratch: FileManager.default.temporaryDirectory.appending(path: "lunetta-copied-\(UUID().uuidString)"),
        compress: writeThreeBytes,
        secondsSinceInput: { input.secondsSinceLast },
        waitForInput: { resume in
            input.resume = resume
            return { input.resume = nil }
        },
        show: { seen.cards.append(($0, $1)) },
        onProblem: { seen.problems.append($0) }
    )
    settings.compressCopiedMedia = true
    try await Task.sleep(for: .milliseconds(50))
    #expect(compressor.isChecking)

    compressor.tick()
    #expect(compressor.isChecking)

    input.secondsSinceLast = ClipboardCompressor.stopsCheckingAfter
    compressor.tick()
    #expect(!compressor.isChecking)
    #expect(compressor.isWatching)
    #expect(input.resume != nil)

    pasteboard.clearContents()
    pasteboard.setData(try solidTIFF(), forType: .tiff)
    await compressor.inputResumed()?.value

    #expect(compressor.isChecking)
    #expect(input.resume == nil)
    #expect(seen.cards.count == 1)
}

@MainActor @Test func turningItOffWhileWaitingForInputStopsWaiting() async throws {
    let settings = LunettaSettings(store: Defaults(), defaultSaveFolder: FileManager.default.temporaryDirectory)
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let input = Input()
    input.secondsSinceLast = ClipboardCompressor.stopsCheckingAfter
    let compressor = ClipboardCompressor(
        settings: settings,
        pasteboard: pasteboard,
        secondsSinceInput: { input.secondsSinceLast },
        waitForInput: { resume in
            input.resume = resume
            return { input.resume = nil }
        },
        show: { _, _ in },
        onProblem: { _ in }
    )
    settings.compressCopiedMedia = true
    try await Task.sleep(for: .milliseconds(50))
    compressor.tick()
    #expect(input.resume != nil)

    settings.compressCopiedMedia = false
    try await Task.sleep(for: .milliseconds(50))

    #expect(!compressor.isWatching)
    #expect(input.resume == nil)
}

@MainActor @Test func whatWasOnTheClipboardBeforeTurningItOnStaysAsItIs() async throws {
    let settings = LunettaSettings(store: Defaults(), defaultSaveFolder: FileManager.default.temporaryDirectory)
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    pasteboard.setData(try solidTIFF(), forType: .tiff)
    let compressor = ClipboardCompressor(settings: settings, pasteboard: pasteboard, show: { _, _ in }, onProblem: { _ in })

    settings.compressCopiedMedia = true
    try await Task.sleep(for: .milliseconds(50))

    #expect(compressor.checkForCopy() == nil)
}
