import AppKit
import LunettaCapture
import LunettaCore
import Testing
@testable import Lunetta

@MainActor @Test func uploadAfterCaptureWaitsForTheCompressedFile() async throws {
    let settings = LunettaSettings(store: Defaults(), defaultSaveFolder: FileManager.default.temporaryDirectory)
    settings.uploadAfterCapture = true
    var uploaded: [URL] = []
    let presenter = ThumbnailPresenter(
        settings: settings,
        upload: { file in
            uploaded.append(file)
            return UploadedCapture(
                key: "shots/Ab3.png",
                link: URL(string: "https://shots.example.com/shots/Ab3.png")!,
                bucket: BucketIdentity(endpoint: URL(string: "http://localhost:9000")!, bucket: "shots")
            )
        },
        onUploaded: { _ in },
        pointerLocation: { offScreen }
    )
    let compressed = AsyncStream<Void>.makeStream()
    let compression: PendingCompression = Task {
        for await _ in compressed.stream { break }
        return CompressionResult(originalBytes: 1000, compressedBytes: 380)
    }
    let png = try writePNG()

    presenter.show(png, precomputedThumbnail: nil, compression: compression)
    try await Task.sleep(for: .milliseconds(200))
    #expect(uploaded.isEmpty)

    compressed.continuation.yield()
    _ = await compression.result
    try await Task.sleep(for: .milliseconds(200))
    #expect(uploaded == [png])
}

@MainActor @Test func aRunningCompressionHoldsAutoHideUntilItFinishes() async throws {
    let settings = LunettaSettings(store: Defaults(), defaultSaveFolder: FileManager.default.temporaryDirectory)
    settings.overlayAutoDismiss = true
    let presenter = ThumbnailPresenter(
        settings: settings,
        upload: noUpload,
        onUploaded: { _ in },
        autoDismissDelay: .milliseconds(100),
        pointerLocation: { offScreen }
    )
    let compressed = AsyncStream<Void>.makeStream()
    let compression: PendingCompression = Task {
        for await _ in compressed.stream { break }
        return nil
    }

    presenter.show(try writePNG(), precomputedThumbnail: nil, compression: compression)
    try await Task.sleep(for: .milliseconds(400))
    #expect(presenter.count == 1) // four auto-hide delays in, the card is still there because compression is

    compressed.continuation.yield()
    _ = await compression.result
    try await Task.sleep(for: .milliseconds(400))
    #expect(presenter.count == 0)
}

@MainActor @Test func theCardSummarizesWhatCompressionSaved() {
    #expect(ThumbnailView.compressionSummary(CompressionResult(originalBytes: 1000, compressedBytes: 380)) == "62% smaller")
    #expect(ThumbnailView.compressionSummary(CompressionResult(originalBytes: 100_000, compressedBytes: 99_990)) == "1% smaller")
    #expect(ThumbnailView.compressionSummary(nil) == "Already small")
}

@MainActor @Test func onlyActionsThatReadTheFileWaitForCompression() {
    let waiting = [ThumbnailView.Action.copy, .upload, .saveAs, .annotate, .pin, .close, .expand, .open, .dropped].filter(\.readsTheFile)
    #expect(waiting == [.copy, .upload, .saveAs, .annotate, .pin, .open])
}
