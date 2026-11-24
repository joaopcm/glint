import Foundation
import GlintCore
import Testing
@testable import Glint

final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var respond: (URLRequest) -> Result<(Int, Data), URLError> = { _ in .failure(URLError(.unknown)) }
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        switch Self.respond(request) {
        case .success(let (status, body)):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func stubbedTransport() -> URLSessionS3Transport {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return URLSessionS3Transport(session: URLSession(configuration: configuration))
}

private let putRequest = S3HTTPRequest(
    method: "PUT",
    url: URL(string: "https://shots.s3.us-east-1.amazonaws.com/a.png")!,
    headers: ["Authorization": "AWS4-HMAC-SHA256 test", "Content-Type": "image/png"],
    body: Data("png".utf8)
)

@Suite(.serialized) struct URLSessionS3TransportTests {
    @Test func sendsMethodURLAndHeadersAndReturnsStatusAndBody() async throws {
        StubURLProtocol.respond = { _ in .success((403, Data("<Error><Code>AccessDenied</Code></Error>".utf8))) }
        let response = try await stubbedTransport().send(putRequest)

        #expect(response == S3HTTPResponse(status: 403, body: Data("<Error><Code>AccessDenied</Code></Error>".utf8)))
        let sent = try #require(StubURLProtocol.lastRequest)
        #expect(sent.httpMethod == "PUT")
        #expect(sent.url == putRequest.url)
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "AWS4-HMAC-SHA256 test")
        #expect(sent.value(forHTTPHeaderField: "Content-Type") == "image/png")
    }

    @Test func offlineKeepsTheSystemReason() async {
        StubURLProtocol.respond = { _ in .failure(URLError(.notConnectedToInternet)) }
        await #expect(throws: S3TransportError(reason: "This Mac is offline. (URLError -1009)")) {
            try await stubbedTransport().send(putRequest)
        }
    }

    @Test func unknownHostKeepsTheSystemReason() async {
        StubURLProtocol.respond = { _ in .failure(URLError(.cannotFindHost)) }
        await #expect(throws: S3TransportError(reason: "DNS can't find shots.s3.us-east-1.amazonaws.com. (URLError -1003)")) {
            try await stubbedTransport().send(putRequest)
        }
    }

    @MainActor @Test func connectionTestShowsTheProviderErrorFromTheWire() async throws {
        StubURLProtocol.respond = { _ in .success((403, Data("<Error><Code>AccessDenied</Code><Message>Access Denied</Message></Error>".utf8))) }
        let suite = "GlintTests-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let settings = GlintSettings(store: UserDefaultsStore(defaults: try #require(UserDefaults(suiteName: suite))), defaultSaveFolder: FileManager.default.temporaryDirectory)
        settings.bucketEndpoint = "https://s3.us-east-1.amazonaws.com"
        settings.bucketRegion = "us-east-1"
        settings.bucketName = "shots"
        let access = BucketAccess(settings: settings, credentialStore: NoKeychain(), transport: stubbedTransport())
        access.accessKeyID = "AKIAIOSFODNN7EXAMPLE"
        access.secretAccessKey = "secret"

        await access.testConnection()

        guard case .finished(let result) = access.connectionTest else {
            Issue.record("test connection did not finish: \(access.connectionTest)")
            return
        }
        #expect(!result.succeeded)
        #expect(result.log.hasPrefix("PUT https://shots.s3.us-east-1.amazonaws.com/glint-connection-test-"))
        #expect(result.log.hasSuffix(".txt failed with HTTP 403. AccessDenied: Access Denied"))
    }
}

private final class NoKeychain: CredentialStore {
    private var stored: S3Credentials?
    func load() throws -> S3Credentials? { stored }
    func save(_ credentials: S3Credentials?) throws { stored = credentials }
}
