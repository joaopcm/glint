import Foundation
import GlintCore
import Testing
@testable import Glint

private func withScratchKeychainService(_ body: (KeychainCredentialStore) throws -> Void) throws {
    let store = KeychainCredentialStore(service: "com.joaopcm.glint.tests.\(UUID().uuidString)")
    defer { try? store.save(nil) }
    try body(store)
}

@Test func keychainRoundTripsUpdatesAndDeletesTheKeys() throws {
    try withScratchKeychainService { store in
        #expect(try store.load() == nil)
        try store.save(S3Credentials(accessKeyID: "AKIAFIRST", secretAccessKey: "first/secret"))
        #expect(try store.load() == S3Credentials(accessKeyID: "AKIAFIRST", secretAccessKey: "first/secret"))
        try store.save(S3Credentials(accessKeyID: "AKIASECOND", secretAccessKey: "second/secret"))
        #expect(try store.load() == S3Credentials(accessKeyID: "AKIASECOND", secretAccessKey: "second/secret"))
        try store.save(nil)
        #expect(try store.load() == nil)
    }
}

@MainActor @Test func bucketSecretsLandInTheKeychainAndNeverInUserDefaults() throws {
    let suite = "GlintTests-\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let defaults = try #require(UserDefaults(suiteName: suite))
    try withScratchKeychainService { keychain in
        let settings = GlintSettings(store: UserDefaultsStore(defaults: defaults), defaultSaveFolder: FileManager.default.temporaryDirectory)
        let access = BucketAccess(settings: settings, credentialStore: keychain, transport: URLSessionS3Transport())
        settings.bucketEndpoint = "https://s3.us-east-1.amazonaws.com"
        settings.bucketRegion = "us-east-1"
        settings.bucketName = "shots"
        access.accessKeyID = "AKIAIOSFODNN7EXAMPLE"
        access.secretAccessKey = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"

        #expect(access.credentialError == nil)
        #expect(try keychain.load() == S3Credentials(accessKeyID: "AKIAIOSFODNN7EXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"))
        let persisted = try #require(UserDefaults().persistentDomain(forName: suite))
        #expect(persisted["bucketName"] as? String == "shots")
        let everything = persisted.values.map { "\($0)" }.joined(separator: "\n")
        #expect(!everything.contains("AKIAIOSFODNN7EXAMPLE"))
        #expect(!everything.contains("wJalrXUtnFEMI"))
    }
}
