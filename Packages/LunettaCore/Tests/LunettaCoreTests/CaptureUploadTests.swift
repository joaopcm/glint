import Foundation
import Testing
@testable import LunettaCore

private func temporaryPNG(_ bytes: Data = Data("png bytes".utf8)) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "lunetta-upload-\(UUID().uuidString).png")
    try bytes.write(to: url)
    return url
}

private func client(_ transport: FakeTransport, publicBaseURL: String = "") throws -> S3Client {
    let configuration = try BucketConfiguration(
        endpoint: "http://localhost:9000", region: "us-east-1", bucket: "shots",
        pathStyle: true, keyPrefix: "lunetta", publicBaseURL: publicBaseURL
    )
    return S3Client(configuration: configuration, credentials: testCredentials, transport: transport, now: { fixedDate })
}

@Test func objectIDsAreSixteenBase62Characters() {
    #expect(Set(ObjectID.alphabet).count == 62)
    #expect(ObjectID.alphabet.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) })
    for _ in 0..<10_000 {
        let id = ObjectID.random()
        #expect(id.count == 16)
        #expect(id.allSatisfy(ObjectID.alphabet.contains))
    }
}

@Test func aMillionObjectIDsNeverCollide() {
    let sample = 1_000_000
    var seen = Set<String>(minimumCapacity: sample)
    for _ in 0..<sample {
        seen.insert(ObjectID.random())
    }
    #expect(seen.count == sample)
}

@Test func uploadPutsTheFileInlineAndLinksToTheObjectWhenThereIsNoPublicBaseURL() async throws {
    let transport = FakeTransport([ok()])
    let body = Data("png bytes".utf8)
    let file = try temporaryPNG(body)
    defer { try? FileManager.default.removeItem(at: file) }

    let uploaded = try await client(transport).upload(file, id: "Ab3")

    #expect(uploaded == UploadedCapture(
        key: "lunetta/Ab3.png",
        link: URL(string: "http://localhost:9000/shots/lunetta/Ab3.png")!,
        bucket: BucketIdentity(endpoint: URL(string: "http://localhost:9000")!, bucket: "shots")
    ))
    #expect(transport.requests.count == 1)
    let request = try #require(transport.requests.first)
    #expect(request.method == "PUT")
    #expect(request.url.absoluteString == "http://localhost:9000/shots/lunetta/Ab3.png")
    #expect(request.body == body)
    #expect(request.headers["Content-Type"] == "image/png")
    #expect(request.headers["Content-Disposition"] == "inline")
    #expect(request.headers["Authorization"]?.contains("SignedHeaders=content-disposition;content-type;host;") == true)
}

@Test func uploadSendsARecordingAsVideoMP4SoTheLinkPlaysInline() async throws {
    let transport = FakeTransport([ok()])
    let file = FileManager.default.temporaryDirectory.appending(path: "lunetta-upload-\(UUID().uuidString).mp4")
    try Data("mp4 bytes".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }

    let uploaded = try await client(transport).upload(file, id: "Ab3")

    #expect(uploaded.key == "lunetta/Ab3.mp4")
    #expect(transport.requests.first?.headers["Content-Type"] == "video/mp4")
}

@Test func uploadLinksThroughThePublicBaseURLKeepingItsPath() async throws {
    let file = try temporaryPNG()
    defer { try? FileManager.default.removeItem(at: file) }

    let uploaded = try await client(FakeTransport([ok()]), publicBaseURL: "https://cdn.example.com/screens/").upload(file, id: "Ab3")

    #expect(uploaded.link.absoluteString == "https://cdn.example.com/screens/lunetta/Ab3.png")
}

@Test func uploadNamesTheObjectWithARandomIDAndTheFileExtension() async throws {
    let file = try temporaryPNG()
    defer { try? FileManager.default.removeItem(at: file) }

    let uploaded = try await client(FakeTransport([ok()])).upload(file)

    let name = try #require(uploaded.key.split(separator: "/").last)
    #expect(uploaded.key.hasPrefix("lunetta/"))
    #expect(name.hasSuffix(".png"))
    #expect(name.dropLast(4).count == ObjectID.length)
}

@Test func uploadReportsTheProviderCodeAndMessage() async throws {
    let file = try temporaryPNG()
    defer { try? FileManager.default.removeItem(at: file) }

    await #expect(throws: UploadError.request(.service(
        method: "PUT", url: URL(string: "http://localhost:9000/shots/lunetta/Ab3.png")!,
        status: 403, code: "AccessDenied", message: "Access Denied"
    ))) {
        try await client(FakeTransport([s3Error(403, "AccessDenied", "Access Denied")])).upload(file, id: "Ab3")
    }
    let error = UploadError.request(.service(
        method: "PUT", url: URL(string: "http://localhost:9000/shots/lunetta/Ab3.png")!,
        status: 403, code: "AccessDenied", message: "Access Denied"
    ))
    #expect(error.localizedDescription == "PUT http://localhost:9000/shots/lunetta/Ab3.png failed with HTTP 403. AccessDenied: Access Denied")
}

@Test func uploadOfAMissingFileNamesThePathAndSendsNothing() async throws {
    let transport = FakeTransport([ok()])
    let missing = FileManager.default.temporaryDirectory.appending(path: "lunetta-missing-\(UUID().uuidString).png")

    do {
        _ = try await client(transport).upload(missing, id: "Ab3")
        Issue.record("uploading a missing file succeeded")
    } catch {
        guard case .unreadable(let path, _) = error else {
            Issue.record("expected .unreadable, got \(error)")
            return
        }
        #expect(path == missing.path)
        #expect(error.localizedDescription.hasPrefix("Couldn't read \(missing.path): "))
    }
    #expect(transport.requests.isEmpty)
}

@Test func uploadRefusesAFileOverTheSinglePutLimitWithoutReadingIt() async throws {
    let transport = FakeTransport([ok()])
    let file = try temporaryPNG(Data())
    defer { try? FileManager.default.removeItem(at: file) }
    let handle = try FileHandle(forWritingTo: file)
    try handle.truncate(atOffset: UInt64(S3Client.singlePutLimit) + 1)
    try handle.close()

    await #expect(throws: UploadError.tooLarge(path: file.path, bytes: S3Client.singlePutLimit + 1)) {
        try await client(transport).upload(file, id: "Ab3")
    }
    #expect(transport.requests.isEmpty)
    #expect(UploadError.tooLarge(path: "/a.png", bytes: 5_368_709_121).localizedDescription
        == "/a.png is 5368709121 bytes. One S3 PUT takes at most 5368709120 bytes (5 GiB), and Lunetta doesn't split uploads.")
}

@MainActor @Test func bucketAccessUploadExplainsAMissingBucket() async {
    let settings = LunettaSettings(store: MemoryStore(), defaultSaveFolder: URL(filePath: "/tmp"))
    let access = BucketAccess(settings: settings, credentialStore: MemoryCredentialStore(), transport: FakeTransport([]))

    await #expect(throws: UploadError.notConfigured) { try await access.upload(URL(filePath: "/tmp/a.png")) }
    #expect(UploadError.notConfigured.localizedDescription == "No bucket is set up. Fill in Settings > Upload first.")

    settings.bucketEndpoint = "not-a-url"
    await #expect(throws: UploadError.setup(.endpointInvalid("not-a-url"))) { try await access.upload(URL(filePath: "/tmp/a.png")) }
}

@MainActor @Test func bucketAccessUploadSendsThroughTheConfiguredBucket() async throws {
    let settings = LunettaSettings(store: MemoryStore(), defaultSaveFolder: URL(filePath: "/tmp"))
    settings.bucketEndpoint = "http://localhost:9000"
    settings.bucketRegion = "us-east-1"
    settings.bucketName = "shots"
    settings.bucketPathStyle = true
    settings.bucketPublicBaseURL = "https://shots.example.com"
    let transport = FakeTransport([ok()])
    let access = BucketAccess(settings: settings, credentialStore: MemoryCredentialStore(testCredentials), transport: transport)
    let file = try temporaryPNG()
    defer { try? FileManager.default.removeItem(at: file) }

    let uploaded = try await access.upload(file)

    #expect(uploaded.link.absoluteString == "https://shots.example.com/\(uploaded.key)")
    #expect(transport.requests.first?.url.absoluteString == "http://localhost:9000/shots/\(uploaded.key)")
}

@MainActor private func shotsAccess(_ transport: FakeTransport) -> BucketAccess {
    let settings = LunettaSettings(store: MemoryStore(), defaultSaveFolder: URL(filePath: "/tmp"))
    settings.bucketEndpoint = "http://localhost:9000"
    settings.bucketRegion = "us-east-1"
    settings.bucketName = "shots"
    settings.bucketPathStyle = true
    return BucketAccess(settings: settings, credentialStore: MemoryCredentialStore(testCredentials), transport: transport)
}

@MainActor @Test func replacingAnUploadPutsOverItsKeySoTheSharedLinkShowsTheNewBytes() async throws {
    let transport = FakeTransport([ok()])
    let body = Data("annotated png bytes".utf8)
    let file = try temporaryPNG(body)
    defer { try? FileManager.default.removeItem(at: file) }
    let earlier = UploadedCapture(
        key: "Ab3.png",
        link: URL(string: "http://localhost:9000/shots/Ab3.png")!,
        bucket: BucketIdentity(endpoint: URL(string: "http://localhost:9000")!, bucket: "shots")
    )

    let uploaded = try await shotsAccess(transport).upload(file, replacing: earlier)

    #expect(uploaded == earlier)
    let request = try #require(transport.requests.first)
    #expect(request.method == "PUT")
    #expect(request.url.absoluteString == "http://localhost:9000/shots/Ab3.png")
    #expect(request.body == body)
}

@MainActor @Test func replacingAnUploadFromAnotherBucketUploadsANewObject() async throws {
    let transport = FakeTransport([ok()])
    let file = try temporaryPNG()
    defer { try? FileManager.default.removeItem(at: file) }
    let elsewhere = UploadedCapture(
        key: "Ab3.png",
        link: URL(string: "http://localhost:9000/old/Ab3.png")!,
        bucket: BucketIdentity(endpoint: URL(string: "http://localhost:9000")!, bucket: "old")
    )

    let uploaded = try await shotsAccess(transport).upload(file, replacing: elsewhere)

    #expect(uploaded.key != elsewhere.key)
    #expect(uploaded.bucket.bucket == "shots")
    #expect(transport.requests.first?.url.absoluteString == "http://localhost:9000/shots/\(uploaded.key)")
}
