import AppKit
import GlintCore
import Testing
@testable import Glint

@MainActor let noUpload: @MainActor (URL) async throws -> UploadedCapture = { _ in
    Issue.record("a thumbnail uploaded without being asked to")
    throw UploadError.notConfigured
}

@MainActor private final class UploadLog {
    var files: [URL] = []
    var reported: [UploadedCapture] = []
}

@MainActor @Test func uploadAfterCaptureUploadsTheNewCaptureReportsItsLinkAndClosesTheCard() async throws {
    let settings = GlintSettings(store: Defaults(), defaultSaveFolder: FileManager.default.temporaryDirectory)
    settings.uploadAfterCapture = true
    let log = UploadLog()
    let uploaded = UploadedCapture(
        key: "shots/Ab3.png",
        link: URL(string: "https://shots.example.com/shots/Ab3.png")!,
        bucket: BucketIdentity(endpoint: URL(string: "http://localhost:9000")!, bucket: "shots")
    )
    let presenter = ThumbnailPresenter(
        settings: settings,
        upload: { file in
            log.files.append(file)
            return uploaded
        },
        onUploaded: { log.reported.append($0) },
        pointerLocation: { offScreen }
    )
    let png = try writePNG()

    presenter.show(png)
    try await Task.sleep(for: .milliseconds(200))

    #expect(log.files == [png])
    #expect(log.reported == [uploaded])
    #expect(presenter.count == 0)
}

@MainActor @Test func uploadAfterCaptureOffLeavesTheCaptureOnThisMac() async throws {
    let settings = GlintSettings(store: Defaults(), defaultSaveFolder: FileManager.default.temporaryDirectory)
    let presenter = ThumbnailPresenter(settings: settings, upload: noUpload, onUploaded: { _ in }, pointerLocation: { offScreen })

    presenter.show(try writePNG())
    try await Task.sleep(for: .milliseconds(200))

    #expect(presenter.count == 1)
}

@MainActor @Test func debugBuildsTakeBucketKeysFromTheUITestEnvironmentOnlyWhenBothAreSet() throws {
    #expect(EnvironmentCredentialStore(environment: [:]) == nil)
    #expect(EnvironmentCredentialStore(environment: [EnvironmentCredentialStore.accessKeyIDVariable: "id"]) == nil)
    let store = try #require(EnvironmentCredentialStore(environment: [
        EnvironmentCredentialStore.accessKeyIDVariable: "id",
        EnvironmentCredentialStore.secretAccessKeyVariable: "secret",
    ]))
    #expect(try store.load() == S3Credentials(accessKeyID: "id", secretAccessKey: "secret"))
}

@MainActor @Test func aRunningUploadHoldsAutoHideUntilItFinishes() async throws {
    let settings = GlintSettings(store: Defaults(), defaultSaveFolder: FileManager.default.temporaryDirectory)
    settings.overlayAutoDismiss = true
    settings.uploadAfterCapture = true
    let bucketAnswers = AsyncStream<Void>.makeStream()
    let reported = AsyncStream<UploadedCapture>.makeStream()
    let uploaded = UploadedCapture(
        key: "shots/Ab3.png",
        link: URL(string: "https://shots.example.com/shots/Ab3.png")!,
        bucket: BucketIdentity(endpoint: URL(string: "http://localhost:9000")!, bucket: "shots")
    )
    let presenter = ThumbnailPresenter(
        settings: settings,
        upload: { _ in
            for await _ in bucketAnswers.stream { break }
            return uploaded
        },
        onUploaded: { reported.continuation.yield($0) },
        autoDismissDelay: .milliseconds(100),
        pointerLocation: { offScreen }
    )

    presenter.show(try writePNG())
    try await Task.sleep(for: .milliseconds(400))
    #expect(presenter.count == 1) // four auto-hide delays in, the card is still there because the upload is

    bucketAnswers.continuation.yield()
    var links = reported.stream.makeAsyncIterator()
    #expect(await links.next() == uploaded)
    #expect(presenter.count == 0)
}
