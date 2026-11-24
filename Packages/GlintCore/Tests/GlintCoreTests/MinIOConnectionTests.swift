import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import GlintCore

private struct MinIO {
    let endpoint: String
    let rootUser: String
    let rootSecret: String
    let readerUser: String
    let readerSecret: String
    let bucket: String

    static let environment: MinIO? = {
        let env = ProcessInfo.processInfo.environment
        guard let endpoint = env["GLINT_MINIO_ENDPOINT"] else { return nil }
        return MinIO(
            endpoint: endpoint,
            rootUser: env["GLINT_MINIO_ROOT_USER"] ?? "",
            rootSecret: env["GLINT_MINIO_ROOT_PASSWORD"] ?? "",
            readerUser: env["GLINT_MINIO_READER_USER"] ?? "",
            readerSecret: env["GLINT_MINIO_READER_PASSWORD"] ?? "",
            bucket: env["GLINT_MINIO_BUCKET"] ?? ""
        )
    }()

    func run(bucket: String? = nil, accessKeyID: String? = nil, secret: String? = nil) async throws -> ConnectionTestResult {
        let configuration = try BucketConfiguration(
            endpoint: endpoint, region: "us-east-1", bucket: bucket ?? self.bucket,
            pathStyle: true, keyPrefix: "ci", publicBaseURL: ""
        )
        let credentials = S3Credentials(accessKeyID: accessKeyID ?? rootUser, secretAccessKey: secret ?? rootSecret)
        return await ConnectionTest.run(client: S3Client(configuration: configuration, credentials: credentials, transport: RealTransport()))
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

@Suite(.enabled(if: MinIO.environment != nil, "set GLINT_MINIO_ENDPOINT to run against a real MinIO (CI's core-linux job does)"))
struct MinIOConnectionTests {
    fileprivate let minio = MinIO.environment!

    @Test func theRightKeysPassThePutAndDelete() async throws {
        let result = try await minio.run()
        #expect(result.succeeded, "\(result.log)")
        #expect(result.log.contains("PUT \(minio.endpoint)/\(minio.bucket)/ci/glint-connection-test-"))
        #expect(result.log.contains("DELETE \(minio.endpoint)/\(minio.bucket)/ci/glint-connection-test-"))
    }

    @Test func aWrongSecretIsSignatureDoesNotMatch() async throws {
        let result = try await minio.run(secret: minio.rootSecret + "x")
        #expect(!result.succeeded)
        #expect(result.log.contains("HTTP 403. SignatureDoesNotMatch"), "\(result.log)")
    }

    @Test func aMissingBucketIsNoSuchBucket() async throws {
        let result = try await minio.run(bucket: "glint-no-such-bucket")
        #expect(!result.succeeded)
        #expect(result.log.contains("HTTP 404. NoSuchBucket"), "\(result.log)")
    }

    @Test func aReadOnlyUserIsAccessDenied() async throws {
        let result = try await minio.run(accessKeyID: minio.readerUser, secret: minio.readerSecret)
        #expect(!result.succeeded)
        #expect(result.log.contains("HTTP 403. AccessDenied"), "\(result.log)")
    }
}
