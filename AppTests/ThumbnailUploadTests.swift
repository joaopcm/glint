import AppKit
import LunettaCore
import Testing
@testable import Lunetta

@MainActor let noUpload: @MainActor (URL, UploadedCapture?) async throws -> UploadedCapture = { _, _ in
    Issue.record("a thumbnail uploaded without being asked to")
    throw UploadError.notConfigured
}

@MainActor private final class UploadLog {
    var files: [URL] = []
    var reported: [UploadedCapture] = []
    var replacing: [UploadedCapture?] = []
}

private let shotsUpload = UploadedCapture(
    key: "shots/Ab3.png",
    link: URL(string: "https://shots.example.com/shots/Ab3.png")!,
    bucket: BucketIdentity(endpoint: URL(string: "http://localhost:9000")!, bucket: "shots")
)

@MainActor @Test func uploadAfterCaptureUploadsTheNewCaptureReportsItsLinkAndKeepsTheCard() async throws {
    let settings = LunettaSettings(store: Defaults(), defaultSaveFolder: FileManager.default.temporaryDirectory)
    settings.uploadAfterCapture = true
    let log = UploadLog()
    let uploaded = UploadedCapture(
        key: "shots/Ab3.png",
        link: URL(string: "https://shots.example.com/shots/Ab3.png")!,
        bucket: BucketIdentity(endpoint: URL(string: "http://localhost:9000")!, bucket: "shots")
    )
    let presenter = ThumbnailPresenter(
        settings: settings,
        upload: { file, _ in
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
    #expect(presenter.count == 1)
}

@MainActor @Test func uploadAfterCaptureOffLeavesTheCaptureOnThisMac() async throws {
    let settings = LunettaSettings(store: Defaults(), defaultSaveFolder: FileManager.default.temporaryDirectory)
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
    let settings = LunettaSettings(store: Defaults(), defaultSaveFolder: FileManager.default.temporaryDirectory)
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
        upload: { _, _ in
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
    #expect(presenter.count == 1)
    try await Task.sleep(for: .milliseconds(400))
    #expect(presenter.count == 0) // the finished upload hands the card back to auto-hide
}

@MainActor @Test func savingAnnotationsOnAnUploadedCapturePutsThemBehindTheSameLink() async throws {
    let settings = LunettaSettings(store: Defaults(), defaultSaveFolder: FileManager.default.temporaryDirectory)
    settings.uploadAfterCapture = true
    let log = UploadLog()
    let presenter = ThumbnailPresenter(
        settings: settings,
        upload: { _, earlier in
            log.replacing.append(earlier)
            return shotsUpload
        },
        onUploaded: { log.reported.append($0) },
        pointerLocation: { offScreen }
    )
    let png = try writePNG()
    presenter.show(png)
    try await Task.sleep(for: .milliseconds(200))

    presenter.annotationsSaved(to: png, try CaptureEditor.image(at: png))
    try await Task.sleep(for: .milliseconds(200))

    #expect(log.replacing == [nil, shotsUpload])
    #expect(log.reported == [shotsUpload, shotsUpload])
    #expect(presenter.count == 1)
}

@MainActor @Test func annotationsSavedDuringTheFirstUploadGoUpOnceItFinishes() async throws {
    let settings = LunettaSettings(store: Defaults(), defaultSaveFolder: FileManager.default.temporaryDirectory)
    settings.uploadAfterCapture = true
    let log = UploadLog()
    let bucketAnswers = AsyncStream<Void>.makeStream()
    let presenter = ThumbnailPresenter(
        settings: settings,
        upload: { _, earlier in
            log.replacing.append(earlier)
            if earlier == nil {
                for await _ in bucketAnswers.stream { break }
            }
            return shotsUpload
        },
        onUploaded: { log.reported.append($0) },
        pointerLocation: { offScreen }
    )
    let png = try writePNG()
    presenter.show(png)
    try await Task.sleep(for: .milliseconds(100))

    presenter.annotationsSaved(to: png, try CaptureEditor.image(at: png))
    try await Task.sleep(for: .milliseconds(100))
    #expect(log.replacing == [nil])

    bucketAnswers.continuation.yield()
    try await Task.sleep(for: .milliseconds(200))
    #expect(log.replacing == [nil, shotsUpload])
    #expect(log.reported == [shotsUpload, shotsUpload])
}

@MainActor @Test func savingAnnotationsOnACaptureNeverUploadedKeepsItOnThisMac() async throws {
    let settings = LunettaSettings(store: Defaults(), defaultSaveFolder: FileManager.default.temporaryDirectory)
    let presenter = ThumbnailPresenter(settings: settings, upload: noUpload, onUploaded: { _ in }, pointerLocation: { offScreen })
    let png = try writePNG()
    presenter.show(png)

    presenter.annotationsSaved(to: png, try CaptureEditor.image(at: png))
    try await Task.sleep(for: .milliseconds(200))

    #expect(presenter.count == 1)
}
