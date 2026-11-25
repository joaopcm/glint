import Foundation
import Observation

public protocol CredentialStore {
    func load() throws -> S3Credentials?
    func save(_ credentials: S3Credentials?) throws
}

public enum ConnectionTestState: Equatable, Sendable {
    case idle
    case running(ConnectionTestResult)
    case finished(ConnectionTestResult)

    public var result: ConnectionTestResult? {
        switch self {
        case .idle: nil
        case .running(let result), .finished(let result): result
        }
    }

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

public enum MakePublicState: Equatable, Sendable {
    case idle
    case running
    case finished(MakePublicResult)
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
    public private(set) var makePublic: MakePublicState = .idle
    public private(set) var bucketURLError: String?

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

    public var provider: StorageProvider? {
        StorageProvider.hosting(endpoint: settings.bucketEndpoint)
    }

    public var publicLinkAdvice: PublicLinkAdvice? {
        try? client().map { PublicLinkAdvice(for: $0.configuration) }
    }

    public func testConnection() async {
        makePublic = .idle
        await runConnectionTest()
    }

    public func makeLinksPublic() async {
        let client: S3Client
        do {
            guard let configured = try self.client() else {
                makePublic = .finished(MakePublicResult(succeeded: false, log: "No bucket is set up. Fill in the endpoint URL, region, bucket and keys.", policyToPaste: nil))
                return
            }
            client = configured
        } catch {
            makePublic = .finished(MakePublicResult(succeeded: false, log: error.localizedDescription, policyToPaste: nil))
            return
        }
        makePublic = .running
        let result = await MakeLinksPublic.run(client: client)
        makePublic = .finished(result)
        if result.succeeded {
            await runConnectionTest()
        }
    }

    public func fill(fromBucketURL text: String) {
        guard let location = BucketLocation.parse(text) else {
            bucketURLError = "Glint can't read a bucket from \(text). Paste a bucket URL like https://my-bucket.s3.us-east-2.amazonaws.com or s3://my-bucket/shots."
            return
        }
        bucketURLError = nil
        if let endpoint = location.endpoint { settings.bucketEndpoint = endpoint }
        if let region = location.region { settings.bucketRegion = region }
        settings.bucketName = location.bucket
        settings.bucketPathStyle = location.pathStyle
        settings.bucketKeyPrefix = location.keyPrefix
    }

    public func apply(_ provider: StorageProvider) {
        let preset = provider.preset(currentRegion: settings.bucketRegion)
        settings.bucketEndpoint = preset.endpoint
        settings.bucketRegion = preset.region
        settings.bucketPathStyle = preset.pathStyle
    }

    private func runConnectionTest() async {
        connectionTest = .running(.waiting)
        let client: S3Client?
        do {
            client = try self.client()
        } catch {
            connectionTest = .finished(.setupFailed(error.localizedDescription))
            return
        }
        guard let client else {
            connectionTest = .finished(.setupFailed("Nothing to test yet. Fill in the endpoint URL, region, bucket and keys."))
            return
        }
        let result = await ConnectionTest.run(client: client) { progress in
            await MainActor.run { self.connectionTest = .running(progress) }
        }
        connectionTest = .finished(result)
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
