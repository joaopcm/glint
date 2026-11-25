import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import LunettaCore

private struct MinIO {
    let endpoint: String
    let rootUser: String
    let rootSecret: String
    let readerUser: String
    let readerSecret: String
    let bucket: String
    let publicBucket: String
    let policyBucket: String

    static let environment: MinIO? = {
        let env = ProcessInfo.processInfo.environment
        guard let endpoint = env["LUNETTA_MINIO_ENDPOINT"] else { return nil }
        return MinIO(
            endpoint: endpoint,
            rootUser: env["LUNETTA_MINIO_ROOT_USER"] ?? "",
            rootSecret: env["LUNETTA_MINIO_ROOT_PASSWORD"] ?? "",
            readerUser: env["LUNETTA_MINIO_READER_USER"] ?? "",
            readerSecret: env["LUNETTA_MINIO_READER_PASSWORD"] ?? "",
            bucket: env["LUNETTA_MINIO_BUCKET"] ?? "",
            publicBucket: env["LUNETTA_MINIO_PUBLIC_BUCKET"] ?? "",
            policyBucket: env["LUNETTA_MINIO_POLICY_BUCKET"] ?? ""
        )
    }()

    func client(bucket: String? = nil, accessKeyID: String? = nil, secret: String? = nil) throws -> S3Client {
        let configuration = try BucketConfiguration(
            endpoint: endpoint, region: "us-east-1", bucket: bucket ?? self.bucket,
            pathStyle: true, keyPrefix: "ci", publicBaseURL: ""
        )
        let credentials = S3Credentials(accessKeyID: accessKeyID ?? rootUser, secretAccessKey: secret ?? rootSecret)
        return S3Client(configuration: configuration, credentials: credentials, transport: RealTransport())
    }

    func run(bucket: String? = nil, accessKeyID: String? = nil, secret: String? = nil) async throws -> ConnectionTestResult {
        await ConnectionTest.run(client: try client(bucket: bucket, accessKeyID: accessKeyID, secret: secret))
    }
}

private struct RealTransport: S3Transport {
    func send(_ request: S3HTTPRequest) async throws(S3TransportError) -> S3HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body.isEmpty ? nil : request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        do {
            let (data, response) = try await URLSession(configuration: .ephemeral).data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else { throw S3TransportError(reason: "the response isn't HTTP") }
            return S3HTTPResponse(status: http.statusCode, body: data)
        } catch let error as S3TransportError {
            throw error
        } catch {
            throw S3TransportError(reason: error.localizedDescription)
        }
    }
}

@Suite(.enabled(if: MinIO.environment != nil, "set LUNETTA_MINIO_ENDPOINT to run against a real MinIO (CI's core-linux job does)"))
struct MinIOConnectionTests {
    fileprivate let minio = MinIO.environment!

    @Test func theRightKeysPassThePutAndDelete() async throws {
        let result = try await minio.run()
        #expect(result.succeeded, "\(result.log)")
        #expect(result.log.contains("PUT \(minio.endpoint)/\(minio.bucket)/ci/lunetta-connection-test-"))
        #expect(result.log.contains("DELETE \(minio.endpoint)/\(minio.bucket)/ci/lunetta-connection-test-"))
    }

    @Test func aWrongSecretIsSignatureDoesNotMatch() async throws {
        let result = try await minio.run(secret: minio.rootSecret + "x")
        #expect(!result.succeeded)
        #expect(result.log.contains("HTTP 403. SignatureDoesNotMatch"), "\(result.log)")
    }

    @Test func aMissingBucketIsNoSuchBucket() async throws {
        let result = try await minio.run(bucket: "lunetta-no-such-bucket")
        #expect(!result.succeeded)
        #expect(result.log.contains("HTTP 404. NoSuchBucket"), "\(result.log)")
    }

    @Test func aReadOnlyUserIsAccessDenied() async throws {
        let result = try await minio.run(accessKeyID: minio.readerUser, secret: minio.readerSecret)
        #expect(!result.succeeded)
        #expect(result.log.contains("HTTP 403. AccessDenied"), "\(result.log)")
    }

    @Test func aPrivateBucketsLinkIsBlockedAndTheTestObjectIsStillDeleted() async throws {
        let result = try await minio.run()
        #expect(result.publicLink == .blocked(status: 403, code: "AccessDenied"), "\(result.log)")
        #expect(result.log.contains("without keys: HTTP 403 AccessDenied"), "\(result.log)")
        #expect(result.log.contains("DELETE \(minio.endpoint)/\(minio.bucket)/ci/lunetta-connection-test-"), "\(result.log)")
    }

    @Test func anAnonymousDownloadBucketsLinkOpens() async throws {
        let result = try await minio.run(bucket: minio.publicBucket)
        #expect(result.succeeded, "\(result.log)")
        #expect(result.publicLink == .opens, "\(result.log)")
    }

    @Test func theGeneratedPublicReadPolicyOpensTheLink() async throws {
        let client = try minio.client(bucket: minio.policyBucket)
        let policy = BucketPolicy.publicRead(bucket: minio.policyBucket, keyPrefix: "ci")
        let current = try await client.getBucketPolicy()
        if let current, let merged = try BucketPolicy.addingPublicRead(bucket: minio.policyBucket, keyPrefix: "ci", to: current) {
            try await client.putBucketPolicy(merged)
        } else if current == nil {
            try await client.putBucketPolicy(policy)
        }
        #expect(try await client.getBucketPolicy() != nil)

        let result = await ConnectionTest.run(client: client)
        #expect(result.publicLink == .opens, "\(result.log)")
    }
}
