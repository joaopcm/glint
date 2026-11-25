import Foundation
import Testing
@testable import LunettaCore

final class MemoryCredentialStore: CredentialStore {
    var stored: S3Credentials?
    var failure: (any Error)?

    init(_ stored: S3Credentials? = nil) {
        self.stored = stored
    }

    func load() throws -> S3Credentials? {
        if let failure { throw failure }
        return stored
    }

    func save(_ credentials: S3Credentials?) throws {
        if let failure { throw failure }
        stored = credentials
    }
}

struct StoreFailure: Error, LocalizedError {
    var errorDescription: String? { "Keychain said no (OSStatus -25308)" }
}

@MainActor private func filledSettings(_ store: MemoryStore = MemoryStore()) -> LunettaSettings {
    let settings = LunettaSettings(store: store, defaultSaveFolder: URL(filePath: "/tmp"))
    settings.bucketEndpoint = "http://localhost:9000"
    settings.bucketRegion = "us-east-1"
    settings.bucketName = "shots"
    settings.bucketPathStyle = true
    settings.bucketKeyPrefix = "lunetta"
    settings.bucketPublicBaseURL = "https://shots.example.com"
    return settings
}

@MainActor @Test func bucketFieldsRoundTripThroughTheStore() {
    let store = MemoryStore()
    _ = filledSettings(store)
    let reloaded = LunettaSettings(store: store, defaultSaveFolder: URL(filePath: "/tmp"))
    #expect(reloaded.bucketEndpoint == "http://localhost:9000")
    #expect(reloaded.bucketRegion == "us-east-1")
    #expect(reloaded.bucketName == "shots")
    #expect(reloaded.bucketPathStyle == true)
    #expect(reloaded.bucketKeyPrefix == "lunetta")
    #expect(reloaded.bucketPublicBaseURL == "https://shots.example.com")
}

@MainActor @Test func secretsGoToTheCredentialStoreAndNeverToTheKeyValueStore() {
    let defaults = MemoryStore()
    let keychain = MemoryCredentialStore()
    let access = BucketAccess(settings: filledSettings(defaults), credentialStore: keychain, transport: FakeTransport([]))

    access.accessKeyID = "AKIAIOSFODNN7EXAMPLE"
    access.secretAccessKey = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"

    #expect(keychain.stored == S3Credentials(accessKeyID: "AKIAIOSFODNN7EXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"))
    let persisted = defaults.values.values.map { "\($0)" }
    #expect(!persisted.contains { $0.contains("AKIAIOSFODNN7EXAMPLE") || $0.contains("wJalrXUtnFEMI") })
}

@MainActor @Test func credentialsLoadFromTheStore() {
    let access = BucketAccess(settings: filledSettings(), credentialStore: MemoryCredentialStore(testCredentials), transport: FakeTransport([]))
    #expect(access.accessKeyID == testCredentials.accessKeyID)
    #expect(access.secretAccessKey == testCredentials.secretAccessKey)
}

@MainActor @Test func clearingBothKeysDeletesThemFromTheStore() {
    let keychain = MemoryCredentialStore(testCredentials)
    let access = BucketAccess(settings: filledSettings(), credentialStore: keychain, transport: FakeTransport([]))
    access.accessKeyID = ""
    access.secretAccessKey = ""
    #expect(keychain.stored == nil)
}

@MainActor @Test func credentialStoreFailuresAreShownNotSwallowed() {
    let keychain = MemoryCredentialStore()
    keychain.failure = StoreFailure()
    let access = BucketAccess(settings: filledSettings(), credentialStore: keychain, transport: FakeTransport([]))
    #expect(access.credentialError == "Couldn't read the bucket keys from the Keychain: Keychain said no (OSStatus -25308)")
    access.accessKeyID = "AKIA"
    #expect(access.credentialError == "Couldn't save the bucket keys to the Keychain: Keychain said no (OSStatus -25308)")
}

@MainActor @Test func nothingConfiguredMeansNoClientAndNoError() throws {
    let settings = LunettaSettings(store: MemoryStore(), defaultSaveFolder: URL(filePath: "/tmp"))
    let access = BucketAccess(settings: settings, credentialStore: MemoryCredentialStore(), transport: FakeTransport([]))
    #expect(try access.client() == nil)
}

@MainActor @Test func halfConfiguredNamesTheMissingPiece() {
    let access = BucketAccess(settings: filledSettings(), credentialStore: MemoryCredentialStore(), transport: FakeTransport([]))
    #expect(throws: BucketSetupError.accessKeyIDMissing) { try access.client() }
    access.accessKeyID = "AKIA"
    #expect(throws: BucketSetupError.secretMissing) { try access.client() }
    access.secretAccessKey = "secret"
    access.settings.bucketRegion = ""
    #expect(throws: BucketSetupError.regionMissing) { try access.client() }
}

@MainActor @Test func testConnectionReportsTheRawResult() async {
    let transport = FakeTransport([ok(200), ok(200), ok(204)])
    let access = BucketAccess(settings: filledSettings(), credentialStore: MemoryCredentialStore(testCredentials), transport: transport)
    await access.testConnection()
    guard case .finished(let result) = access.connectionTest else {
        Issue.record("test connection did not finish: \(access.connectionTest)")
        return
    }
    #expect(result.succeeded)
    #expect(result.log.hasPrefix("PUT http://localhost:9000/shots/lunetta/lunetta-connection-test-"))
    #expect(transport.requests.map(\.method) == ["PUT", "GET", "DELETE"])
    #expect(result.steps.map(\.status) == [.passed, .passed, .passed])
}

@MainActor @Test func testConnectionWithNothingConfiguredSaysSoWithoutTouchingTheNetwork() async {
    let transport = FakeTransport([])
    let settings = LunettaSettings(store: MemoryStore(), defaultSaveFolder: URL(filePath: "/tmp"))
    let access = BucketAccess(settings: settings, credentialStore: MemoryCredentialStore(), transport: transport)
    await access.testConnection()
    #expect(access.connectionTest == .finished(.setupFailed("Nothing to test yet. Fill in the endpoint URL, region, bucket and keys.")))
    #expect(transport.requests.isEmpty)
}

@MainActor @Test func testConnectionWithABadFieldShowsTheSetupError() async {
    let settings = filledSettings()
    settings.bucketEndpoint = "s3.example.com"
    let access = BucketAccess(settings: settings, credentialStore: MemoryCredentialStore(testCredentials), transport: FakeTransport([]))
    await access.testConnection()
    #expect(access.connectionTest == .finished(.setupFailed(BucketSetupError.endpointInvalid("s3.example.com").localizedDescription)))
}

@MainActor @Test func pastingABucketURLFillsTheForm() {
    let settings = filledSettings()
    let access = BucketAccess(settings: settings, credentialStore: MemoryCredentialStore(), transport: FakeTransport([]))
    access.fill(fromBucketURL: "https://lunetta-captures.s3.us-east-2.amazonaws.com")

    #expect(access.bucketURLError == nil)
    #expect(settings.bucketEndpoint == "https://s3.us-east-2.amazonaws.com")
    #expect(settings.bucketRegion == "us-east-2")
    #expect(settings.bucketName == "lunetta-captures")
    #expect(settings.bucketPathStyle == false)
    #expect(settings.bucketKeyPrefix == "")
    #expect(access.provider == .aws)
}

@MainActor @Test func pastingTextThatIsntABucketURLSaysSoAndChangesNothing() {
    let settings = filledSettings()
    let access = BucketAccess(settings: settings, credentialStore: MemoryCredentialStore(), transport: FakeTransport([]))
    access.fill(fromBucketURL: "lunetta-captures")

    #expect(access.bucketURLError == "Lunetta can't read a bucket from lunetta-captures. Paste a bucket URL like https://my-bucket.s3.us-east-2.amazonaws.com or s3://my-bucket/shots.")
    #expect(settings.bucketName == "shots")
}

@MainActor @Test func aPresetKeepsTheBucketAndPrefix() {
    let settings = filledSettings()
    let access = BucketAccess(settings: settings, credentialStore: MemoryCredentialStore(), transport: FakeTransport([]))
    access.apply(.cloudflareR2)

    #expect(settings.bucketEndpoint == "https://<account-id>.r2.cloudflarestorage.com")
    #expect(settings.bucketRegion == "auto")
    #expect(settings.bucketPathStyle)
    #expect(settings.bucketName == "shots")
    #expect(settings.bucketKeyPrefix == "lunetta")
}

@MainActor @Test func makingLinksPublicChecksTheLinkAgain() async {
    let transport = FakeTransport([
        ok(200), s3Error(404, "NoSuchBucketPolicy", "none"), ok(204),
        ok(200), ok(200), ok(204),
    ])
    let access = BucketAccess(settings: filledSettings(), credentialStore: MemoryCredentialStore(testCredentials), transport: transport)
    await access.makeLinksPublic()

    guard case .finished(let made) = access.makePublic, case .finished(let test) = access.connectionTest else {
        Issue.record("make public: \(access.makePublic), test: \(access.connectionTest)")
        return
    }
    #expect(made.succeeded)
    #expect(test.publicLink == .opens)
    #expect(transport.requests.map(\.method) == ["PUT", "GET", "PUT", "PUT", "GET", "DELETE"])
}
