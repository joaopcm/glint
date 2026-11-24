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
    let uploaded = UploadedCapture(key: "shots/Ab3.png", link: URL(string: "https://shots.example.com/shots/Ab3.png")!)
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
