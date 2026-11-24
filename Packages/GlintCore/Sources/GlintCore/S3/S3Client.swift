import Foundation

public struct S3HTTPRequest: Sendable, Equatable {
    public let method: String
    public let url: URL
    public let headers: [String: String]
    public let body: Data

    public init(method: String, url: URL, headers: [String: String], body: Data) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct S3HTTPResponse: Sendable, Equatable {
    public let status: Int
    public let body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

public struct S3TransportError: Error, Equatable {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }
}

public protocol S3Transport: Sendable {
    func send(_ request: S3HTTPRequest) async throws(S3TransportError) -> S3HTTPResponse
}

public enum S3Error: Error, Equatable, LocalizedError {
    case service(method: String, url: URL, status: Int, code: String?, message: String?)
    case transport(method: String, url: URL, reason: String)
    case signing(S3SigningError)

    public var errorDescription: String? {
        switch self {
        case .service(let method, let url, let status, let code?, let message):
            "\(method) \(url.absoluteString) failed with HTTP \(status). \(code)" + (message.map { ": \($0)" } ?? "")
        case .service(let method, let url, let status, nil, _):
            "\(method) \(url.absoluteString) failed with HTTP \(status), and the response isn't an S3 error document."
        case .transport(let method, let url, let reason):
            "\(method) \(url.absoluteString) failed: \(reason)"
        case .signing(let error):
            error.localizedDescription
        }
    }
}

public struct S3Client: Sendable {
    public let configuration: BucketConfiguration
    private let signer: S3Signer
    private let transport: any S3Transport
    private let now: @Sendable () -> Date

    public init(
        configuration: BucketConfiguration,
        credentials: S3Credentials,
        transport: any S3Transport,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.configuration = configuration
        signer = S3Signer(credentials: credentials, region: configuration.region)
        self.transport = transport
        self.now = now
    }

    @discardableResult
    public func put(key: String, body: Data, contentType: String, contentDisposition: String? = nil) async throws(S3Error) -> Int {
        var headers = ["Content-Type": contentType]
        headers["Content-Disposition"] = contentDisposition
        return try await send("PUT", key: key, headers: headers, body: body)
    }

    @discardableResult
    public func delete(key: String) async throws(S3Error) -> Int {
        try await send("DELETE", key: key, headers: [:], body: Data())
    }

    private func send(_ method: String, key: String, headers: [String: String], body: Data) async throws(S3Error) -> Int {
        let url = configuration.objectURL(forKey: key)
        let signed: SignedRequest
        do throws(S3SigningError) {
            signed = try signer.sign(method: method, url: url, headers: headers, payload: .sha256(of: body), date: now())
        } catch {
            throw .signing(error)
        }
        let response: S3HTTPResponse
        do throws(S3TransportError) {
            response = try await transport.send(S3HTTPRequest(method: method, url: url, headers: signed.headers, body: body))
        } catch {
            throw .transport(method: method, url: url, reason: error.reason)
        }
        guard (200..<300).contains(response.status) else {
            let document = S3ErrorDocument(xml: response.body)
            throw .service(method: method, url: url, status: response.status, code: document?.code, message: document?.message)
        }
        return response.status
    }
}
