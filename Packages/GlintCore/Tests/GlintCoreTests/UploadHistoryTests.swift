import Foundation
import Testing
@testable import GlintCore

private func temporaryHistoryFile() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "glint-history-\(UUID().uuidString)/upload-history.json")
}

private let shotsBucket = BucketIdentity(endpoint: URL(string: "http://localhost:9000")!, bucket: "shots")

private func uploaded(_ name: String) -> UploadedCapture {
    UploadedCapture(key: "glint/\(name).png", link: URL(string: "https://shots.example.com/glint/\(name).png")!, bucket: shotsBucket)
}

@MainActor private func shotsAccess(_ transport: FakeTransport) -> BucketAccess {
    let settings = GlintSettings(store: MemoryStore(), defaultSaveFolder: URL(filePath: "/tmp"))
    settings.bucketEndpoint = "http://localhost:9000"
    settings.bucketRegion = "us-east-1"
    settings.bucketName = "shots"
    settings.bucketPathStyle = true
    return BucketAccess(settings: settings, credentialStore: MemoryCredentialStore(testCredentials), transport: transport)
}

private struct DeleteRefused: Error, LocalizedError {
    var errorDescription: String? { "DELETE http://localhost:9000/shots/glint/a.png failed with HTTP 403. AccessDenied: Access Denied" }
}

@MainActor @Test func historyListsUploadsNewestFirst() {
    let history = UploadHistory(file: temporaryHistoryFile())
    history.add(uploaded("a"), at: Date(timeIntervalSince1970: 100))
    history.add(uploaded("b"), at: Date(timeIntervalSince1970: 200))
    history.add(uploaded("c"), at: Date(timeIntervalSince1970: 150))
    #expect(history.records.map(\.key) == ["glint/b.png", "glint/c.png", "glint/a.png"])
    #expect(history.error == nil)
}

@MainActor @Test func historySurvivesARelaunch() {
    let file = temporaryHistoryFile()
    let history = UploadHistory(file: file)
    history.add(uploaded("a"), at: Date(timeIntervalSince1970: 100))
    history.add(uploaded("b"), at: Date(timeIntervalSince1970: 200))

    let reloaded = UploadHistory(file: file)
    #expect(reloaded.records == history.records)
    #expect(reloaded.records.first?.link.absoluteString == "https://shots.example.com/glint/b.png")
    #expect(reloaded.records.first?.date == Date(timeIntervalSince1970: 200))
}

@MainActor @Test func noFileYetIsAnEmptyHistoryNotAnError() {
    let history = UploadHistory(file: temporaryHistoryFile())
    #expect(history.records.isEmpty)
    #expect(history.error == nil)
}

@MainActor @Test func deleteRemovesTheObjectThenTheRow() async {
    let file = temporaryHistoryFile()
    let history = UploadHistory(file: file)
    history.add(uploaded("a"), at: Date(timeIntervalSince1970: 100))
    history.add(uploaded("b"), at: Date(timeIntervalSince1970: 200))
    var deletedKeys: [String] = []

    await history.delete(history.records[1]) { deletedKeys.append($0.key) }

    #expect(deletedKeys == ["glint/a.png"])
    #expect(history.records.map(\.key) == ["glint/b.png"])
    #expect(UploadHistory(file: file).records.map(\.key) == ["glint/b.png"])
    #expect(history.error == nil)
}

@MainActor @Test func aFailedDeleteKeepsTheRowAndSaysWhy() async {
    let file = temporaryHistoryFile()
    let history = UploadHistory(file: file)
    history.add(uploaded("a"), at: Date(timeIntervalSince1970: 100))

    await history.delete(history.records[0]) { _ in throw DeleteRefused() }

    #expect(history.records.map(\.key) == ["glint/a.png"])
    #expect(UploadHistory(file: file).records.map(\.key) == ["glint/a.png"])
    #expect(history.error == "Couldn't delete glint/a.png: DELETE http://localhost:9000/shots/glint/a.png failed with HTTP 403. AccessDenied: Access Denied")
    #expect(history.deleting.isEmpty)
}

@MainActor @Test func deleteThroughTheBucketSendsASignedDELETE() async throws {
    let transport = FakeTransport([ok(204)])
    let bucket = shotsAccess(transport)

    try await bucket.deleteObject(UploadRecord(key: "glint/a.png", link: uploaded("a").link, date: Date(), bucket: shotsBucket))

    let request = try #require(transport.requests.first)
    #expect(request.method == "DELETE")
    #expect(request.url.absoluteString == "http://localhost:9000/shots/glint/a.png")
    #expect(request.headers["Authorization"]?.hasPrefix("AWS4-HMAC-SHA256 ") == true)
}

@MainActor @Test func deleteWithNoBucketSetUpSaysSo() async {
    let settings = GlintSettings(store: MemoryStore(), defaultSaveFolder: URL(filePath: "/tmp"))
    let bucket = BucketAccess(settings: settings, credentialStore: MemoryCredentialStore(), transport: FakeTransport([]))
    let record = UploadRecord(key: "glint/a.png", link: uploaded("a").link, date: Date(), bucket: shotsBucket)
    await #expect(throws: UploadError.notConfigured) { try await bucket.deleteObject(record) }
}

@MainActor @Test func deleteAfterSwitchingBucketsSendsNothingAndNamesBothBuckets() async {
    let file = temporaryHistoryFile()
    let history = UploadHistory(file: file)
    let transport = FakeTransport([])
    let bucket = shotsAccess(transport)
    history.add(uploaded("a"), at: Date(timeIntervalSince1970: 100))
    bucket.settings.bucketEndpoint = "https://s3.us-west-2.amazonaws.com"
    bucket.settings.bucketRegion = "us-west-2"
    bucket.settings.bucketName = "archive"

    await history.delete(history.records[0]) { try await bucket.deleteObject($0) }

    #expect(transport.requests.isEmpty)
    #expect(history.records.map(\.key) == ["glint/a.png"])
    #expect(UploadHistory(file: file).records.map(\.key) == ["glint/a.png"])
    #expect(history.error == "Couldn't delete glint/a.png: It went to shots at http://localhost:9000, "
        + "but Settings > Upload points at archive at https://s3.us-west-2.amazonaws.com now. "
        + "Glint sent nothing. Point Settings > Upload back at shots at http://localhost:9000 to delete it.")
}

@MainActor @Test func aHistoryFileFromBeforeBucketsWereRecordedStillLoadsAndDeletesFromTheCurrentBucket() async throws {
    let file = temporaryHistoryFile()
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"[{"key":"glint/old.png","link":"https://shots.example.com/glint/old.png","date":100}]"#.utf8).write(to: file)
    let transport = FakeTransport([ok(204)])
    let bucket = shotsAccess(transport)

    let history = UploadHistory(file: file)
    #expect(history.error == nil)
    #expect(history.records == [UploadRecord(
        key: "glint/old.png",
        link: URL(string: "https://shots.example.com/glint/old.png")!,
        date: Date(timeIntervalSinceReferenceDate: 100),
        bucket: nil
    )])

    await history.delete(history.records[0]) { try await bucket.deleteObject($0) }

    #expect(transport.requests.map(\.url.absoluteString) == ["http://localhost:9000/shots/glint/old.png"])
    #expect(history.records.isEmpty)
    #expect(history.error == nil)
}

@MainActor @Test func anUnreadableHistoryFileIsReportedAndLeftAlone() throws {
    let file = temporaryHistoryFile()
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("not json".utf8).write(to: file)

    let history = UploadHistory(file: file)
    #expect(history.records.isEmpty)
    #expect(history.error?.hasPrefix("Couldn't read the upload history at \(file.path): ") == true)

    history.add(uploaded("a"), at: Date(timeIntervalSince1970: 100))
    #expect(history.records.map(\.key) == ["glint/a.png"])
    #expect(try Data(contentsOf: file) == Data("not json".utf8))
}
