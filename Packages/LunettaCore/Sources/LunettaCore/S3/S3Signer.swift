import Foundation

public struct S3Credentials: Sendable, Equatable {
    public let accessKeyID: String
    public let secretAccessKey: String
    public let sessionToken: String?

    public init(accessKeyID: String, secretAccessKey: String, sessionToken: String? = nil) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken
    }
}

public struct PayloadHash: Sendable, Equatable {
    public let value: String

    public static let unsigned = PayloadHash(value: "UNSIGNED-PAYLOAD")

    public static func sha256(of body: Data) -> PayloadHash {
        PayloadHash(value: SHA256.hash(body).hex)
    }

    private init(value: String) {
        self.value = value
    }
}

public enum S3SigningError: Error, Equatable, LocalizedError {
    case urlHasNoHost(URL)

    public var errorDescription: String? {
        switch self {
        case .urlHasNoHost(let url):
            "Can't sign the request to \(url.absoluteString): the URL has no host, so there is no endpoint to sign for."
        }
    }
}

public struct S3Signer: Sendable {
    public let credentials: S3Credentials
    public let region: String
    public let service: String

    public init(credentials: S3Credentials, region: String, service: String = "s3") {
        self.credentials = credentials
        self.region = region
        self.service = service
    }

    public func sign(
        method: String,
        url: URL,
        headers: [String: String] = [:],
        payload: PayloadHash,
        date: Date
    ) throws(S3SigningError) -> SignedRequest {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard let components, let host = components.percentEncodedHost, !host.isEmpty else {
            throw .urlHasNoHost(url)
        }
        var signed: [(name: String, value: String)] = []
        signed.reserveCapacity(headers.count + 4)
        for (name, value) in headers where name.caseInsensitiveCompare("host") != .orderedSame {
            signed.append((name: name, value: value))
        }
        signed.append(("host", components.port.map { "\(host):\($0)" } ?? host))
        signed.append(("x-amz-content-sha256", payload.value))
        return SigV4.sign(
            method: method, components: components, headers: signed, payloadHash: payload.value,
            credentials: credentials, region: region, service: service, date: date
        )
    }
}
