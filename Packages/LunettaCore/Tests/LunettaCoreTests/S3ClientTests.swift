import Foundation
import Testing
@testable import LunettaCore

final class FakeTransport: S3Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [Result<S3HTTPResponse, S3TransportError>]
    private var sent: [S3HTTPRequest] = []

    init(_ responses: [Result<S3HTTPResponse, S3TransportError>]) {
        queued = responses
    }

    var requests: [S3HTTPRequest] {
        lock.lock()
        defer { lock.unlock() }
        return sent
    }

    func send(_ request: S3HTTPRequest) async throws(S3TransportError) -> S3HTTPResponse {
        try record(request).get()
    }

    private func record(_ request: S3HTTPRequest) -> Result<S3HTTPResponse, S3TransportError> {
        lock.lock()
        defer { lock.unlock() }
        sent.append(request)
        return queued.isEmpty ? .failure(S3TransportError(reason: "no response queued")) : queued.removeFirst()
    }
}

func ok(_ status: Int = 200) -> Result<S3HTTPResponse, S3TransportError> {
    .success(S3HTTPResponse(status: status, body: Data()))
}

func s3Error(_ status: Int, _ code: String, _ message: String) -> Result<S3HTTPResponse, S3TransportError> {
    .success(S3HTTPResponse(status: status, body: Data("<Error><Code>\(code)</Code><Message>\(message)</Message></Error>".utf8)))
}

let minio = try! BucketConfiguration(
    endpoint: "http://localhost:9000", region: "us-east-1", bucket: "shots",
    pathStyle: true, keyPrefix: "lunetta", publicBaseURL: ""
)
let testCredentials = S3Credentials(accessKeyID: "AKIAIOSFODNN7EXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
let fixedDate = Date(timeIntervalSince1970: 1_369_353_600)

func client(_ transport: FakeTransport) -> S3Client {
    S3Client(configuration: minio, credentials: testCredentials, transport: transport, now: { fixedDate })
}

@Test func putSendsASignedRequestWithTheBodyAndItsHash() async throws {
    let transport = FakeTransport([ok()])
    let body = Data("hello".utf8)
    let status = try await client(transport).put(key: "lunetta/a.png", body: body, contentType: "image/png")

    #expect(status == 200)
    let request = try #require(transport.requests.first)
    #expect(request.method == "PUT")
    #expect(request.url.absoluteString == "http://localhost:9000/shots/lunetta/a.png")
    #expect(request.body == body)
    #expect(request.headers["Content-Type"] == "image/png")
    #expect(request.headers["x-amz-content-sha256"] == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    #expect(request.headers["x-amz-date"] == "20130524T000000Z")
    let authorization = try #require(request.headers["Authorization"])
    #expect(authorization.hasPrefix("AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date, Signature="))
    #expect(request.headers["Host"] == nil)
}

@Test func deleteSendsAnEmptySignedBody() async throws {
    let transport = FakeTransport([ok(204)])
    #expect(try await client(transport).delete(key: "lunetta/a.png") == 204)
    let request = try #require(transport.requests.first)
    #expect(request.method == "DELETE")
    #expect(request.body.isEmpty)
    #expect(request.headers["x-amz-content-sha256"] == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
}

@Test func serviceErrorCarriesTheProviderCodeMessageStatusAndURL() async {
    let transport = FakeTransport([s3Error(403, "AccessDenied", "Access Denied")])
    let url = URL(string: "http://localhost:9000/shots/lunetta/a.png")!
    await #expect(throws: S3Error.service(method: "PUT", url: url, status: 403, code: "AccessDenied", message: "Access Denied")) {
        try await client(transport).put(key: "lunetta/a.png", body: Data(), contentType: "image/png")
    }
    #expect(S3Error.service(method: "PUT", url: url, status: 403, code: "AccessDenied", message: "Access Denied").localizedDescription
        == "PUT http://localhost:9000/shots/lunetta/a.png failed with HTTP 403. AccessDenied: Access Denied")
}

@Test func nonXMLServerErrorStillNamesTheStatus() async {
    let transport = FakeTransport([.success(S3HTTPResponse(status: 502, body: Data("<html>Bad Gateway</html>".utf8)))])
    let url = URL(string: "http://localhost:9000/shots/lunetta/a.png")!
    await #expect(throws: S3Error.service(method: "DELETE", url: url, status: 502, code: nil, message: nil)) {
        try await client(transport).delete(key: "lunetta/a.png")
    }
    #expect(S3Error.service(method: "DELETE", url: url, status: 502, code: nil, message: nil).localizedDescription
        == "DELETE http://localhost:9000/shots/lunetta/a.png failed with HTTP 502, and the response isn't an S3 error document.")
}

@Test func transportErrorKeepsTheSystemReason() async {
    let transport = FakeTransport([.failure(S3TransportError(reason: "The Internet connection appears to be offline."))])
    let url = URL(string: "http://localhost:9000/shots/lunetta/a.png")!
    await #expect(throws: S3Error.transport(method: "PUT", url: url, reason: "The Internet connection appears to be offline.")) {
        try await client(transport).put(key: "lunetta/a.png", body: Data(), contentType: "image/png")
    }
    #expect(S3Error.transport(method: "PUT", url: url, reason: "A server with the specified hostname could not be found.").localizedDescription
        == "PUT http://localhost:9000/shots/lunetta/a.png failed: A server with the specified hostname could not be found.")
}
