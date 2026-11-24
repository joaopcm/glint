import Foundation
import Observation

public protocol CredentialStore {
    func load() throws -> S3Credentials?
    func save(_ credentials: S3Credentials?) throws
}

public enum ConnectionTestState: Equatable, Sendable {
    case idle
    case running
    case finished(ConnectionTestResult)
}

@MainActor @Observable
public final class BucketAccess {
    public let settings: GlintSettings
    private let credentialStore: any CredentialStore
    private let transport: any S3Transport

    public var accessKeyID: String {
        didSet { saveCredentials() }
    }

    public var secretAccessKey: String {
        didSet { saveCredentials() }
    }

    public private(set) var credentialError: String?
    public private(set) var connectionTest: ConnectionTestState = .idle

    public init(settings: GlintSettings, credentialStore: any CredentialStore, transport: any S3Transport) {
        self.settings = settings
        self.credentialStore = credentialStore
        self.transport = transport
        do {
            let stored = try credentialStore.load()
            accessKeyID = stored?.accessKeyID ?? ""
            secretAccessKey = stored?.secretAccessKey ?? ""
        } catch {
            accessKeyID = ""
            secretAccessKey = ""
            credentialError = "Couldn't read the bucket keys from the Keychain: \(error.localizedDescription)"
        }
    }

    public func client() throws(BucketSetupError) -> S3Client? {
        let fields = [settings.bucketEndpoint, settings.bucketRegion, settings.bucketName, accessKeyID, secretAccessKey]
        if fields.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return nil
        }
        let configuration = try BucketConfiguration(
            endpoint: settings.bucketEndpoint,
            region: settings.bucketRegion,
            bucket: settings.bucketName,
            pathStyle: settings.bucketPathStyle,
            keyPrefix: settings.bucketKeyPrefix,
            publicBaseURL: settings.bucketPublicBaseURL
        )
        let accessKeyID = accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accessKeyID.isEmpty else { throw .accessKeyIDMissing }
        guard !secretAccessKey.isEmpty else { throw .secretMissing }
        return S3Client(
            configuration: configuration,
            credentials: S3Credentials(accessKeyID: accessKeyID, secretAccessKey: secretAccessKey),
            transport: transport
        )
    }

    public func testConnection() async {
        connectionTest = .running
        let client: S3Client?
        do {
            client = try self.client()
        } catch {
            connectionTest = .finished(ConnectionTestResult(succeeded: false, log: error.localizedDescription))
            return
        }
        guard let client else {
            connectionTest = .finished(ConnectionTestResult(
                succeeded: false,
                log: "Nothing to test yet. Fill in the endpoint URL, region, bucket and keys."
            ))
            return
        }
        connectionTest = .finished(await ConnectionTest.run(client: client))
    }

    private func saveCredentials() {
        let credentials = accessKeyID.isEmpty && secretAccessKey.isEmpty
            ? nil
            : S3Credentials(accessKeyID: accessKeyID, secretAccessKey: secretAccessKey)
        do {
            try credentialStore.save(credentials)
            credentialError = nil
        } catch {
            credentialError = "Couldn't save the bucket keys to the Keychain: \(error.localizedDescription)"
        }
    }
}
