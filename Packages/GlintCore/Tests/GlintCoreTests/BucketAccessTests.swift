import Foundation
import Testing
@testable import GlintCore

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

@MainActor private func filledSettings(_ store: MemoryStore = MemoryStore()) -> GlintSettings {
    let settings = GlintSettings(store: store, defaultSaveFolder: URL(filePath: "/tmp"))
    settings.bucketEndpoint = "http://localhost:9000"
    settings.bucketRegion = "us-east-1"
    settings.bucketName = "shots"
    settings.bucketPathStyle = true
    settings.bucketKeyPrefix = "glint"
    settings.bucketPublicBaseURL = "https://shots.example.com"
    return settings
}

@MainActor @Test func bucketFieldsRoundTripThroughTheStore() {
    let store = MemoryStore()
    _ = filledSettings(store)
    let reloaded = GlintSettings(store: store, defaultSaveFolder: URL(filePath: "/tmp"))
    #expect(reloaded.bucketEndpoint == "http://localhost:9000")
    #expect(reloaded.bucketRegion == "us-east-1")
    #expect(reloaded.bucketName == "shots")
    #expect(reloaded.bucketPathStyle == true)
    #expect(reloaded.bucketKeyPrefix == "glint")
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
    let settings = GlintSettings(store: MemoryStore(), defaultSaveFolder: URL(filePath: "/tmp"))
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
    let transport = FakeTransport([ok(200), ok(204)])
    let access = BucketAccess(settings: filledSettings(), credentialStore: MemoryCredentialStore(testCredentials), transport: transport)
    await access.testConnection()
    guard case .finished(let result) = access.connectionTest else {
        Issue.record("test connection did not finish: \(access.connectionTest)")
        return
    }
    #expect(result.succeeded)
    #expect(result.log.hasPrefix("PUT http://localhost:9000/shots/glint/glint-connection-test-"))
    #expect(transport.requests.map(\.method) == ["PUT", "DELETE"])
}

@MainActor @Test func testConnectionWithNothingConfiguredSaysSoWithoutTouchingTheNetwork() async {
    let transport = FakeTransport([])
    let settings = GlintSettings(store: MemoryStore(), defaultSaveFolder: URL(filePath: "/tmp"))
    let access = BucketAccess(settings: settings, credentialStore: MemoryCredentialStore(), transport: transport)
    await access.testConnection()
    #expect(access.connectionTest == .finished(ConnectionTestResult(
        succeeded: false,
        log: "Nothing to test yet. Fill in the endpoint URL, region, bucket and keys."
    )))
    #expect(transport.requests.isEmpty)
}

@MainActor @Test func testConnectionWithABadFieldShowsTheSetupError() async {
    let settings = filledSettings()
    settings.bucketEndpoint = "s3.example.com"
    let access = BucketAccess(settings: settings, credentialStore: MemoryCredentialStore(testCredentials), transport: FakeTransport([]))
    await access.testConnection()
    #expect(access.connectionTest == .finished(ConnectionTestResult(
        succeeded: false,
        log: BucketSetupError.endpointInvalid("s3.example.com").localizedDescription
    )))
}
