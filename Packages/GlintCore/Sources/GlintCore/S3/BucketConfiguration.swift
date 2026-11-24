import Foundation

public enum BucketSetupError: Error, Equatable, LocalizedError {
    case endpointMissing
    case endpointInvalid(String)
    case endpointHasPath(String)
    case regionMissing
    case bucketMissing
    case bucketInvalid(String)
    case publicBaseURLInvalid(String)
    case accessKeyIDMissing
    case secretMissing

    public var errorDescription: String? {
        switch self {
        case .endpointMissing:
            "Endpoint URL is empty."
        case .endpointInvalid(let endpoint):
            "The endpoint URL \(endpoint) isn't an http:// or https:// URL with a host."
        case .endpointHasPath(let endpoint):
            "The endpoint URL \(endpoint) has a path. Put only the scheme and host there (\(Self.schemeAndHost(of: endpoint))) and the bucket name in Bucket."
        case .regionMissing:
            "Region is empty. Use the bucket's region (us-east-1 on AWS, auto on Cloudflare R2)."
        case .bucketMissing:
            "Bucket is empty."
        case .bucketInvalid(let bucket):
            "The bucket name \(bucket) has a slash. Put folders in Key prefix."
        case .publicBaseURLInvalid(let url):
            "The public base URL \(url) isn't an http:// or https:// URL with a host."
        case .accessKeyIDMissing:
            "Access key ID is empty."
        case .secretMissing:
            "Secret access key is empty."
        }
    }

    private static func schemeAndHost(of endpoint: String) -> String {
        guard let components = URLComponents(string: endpoint), let scheme = components.scheme, let host = components.host else {
            return endpoint
        }
        return "\(scheme)://\(host)"
    }
}

public struct BucketConfiguration: Sendable, Equatable {
    public let endpoint: URL
    public let region: String
    public let bucket: String
    public let pathStyle: Bool
    public let keyPrefix: String
    public let publicBaseURL: URL?

    public init(
        endpoint: String,
        region: String,
        bucket: String,
        pathStyle: Bool,
        keyPrefix: String,
        publicBaseURL: String
    ) throws(BucketSetupError) {
        let endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpoint.isEmpty else { throw .endpointMissing }
        guard let normalized = Self.webURL(endpoint) else { throw .endpointInvalid(endpoint) }
        guard normalized.hasNoPath else { throw .endpointHasPath(endpoint) }
        let region = region.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !region.isEmpty else { throw .regionMissing }
        let bucket = bucket.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bucket.isEmpty else { throw .bucketMissing }
        guard !bucket.contains("/") else { throw .bucketInvalid(bucket) }
        let publicBaseURL = publicBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        var publicURL: URL?
        if !publicBaseURL.isEmpty {
            guard let url = Self.webURL(publicBaseURL) else { throw .publicBaseURLInvalid(publicBaseURL) }
            publicURL = url.url
        }

        self.endpoint = normalized.url
        self.region = region
        self.bucket = bucket
        self.pathStyle = pathStyle
        self.keyPrefix = keyPrefix.split(separator: "/").joined(separator: "/")
        self.publicBaseURL = publicURL
    }

    public func objectKey(forName name: String) -> String {
        keyPrefix.isEmpty ? name : "\(keyPrefix)/\(name)"
    }

    public func objectURL(forKey key: String) -> URL {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        let encodedKey = SigV4.uriEncode(key, keepingSlashes: true)
        if pathStyle {
            components.percentEncodedPath = "/\(SigV4.uriEncode(bucket, keepingSlashes: false))/\(encodedKey)"
        } else {
            components.host = "\(bucket).\(components.host!)"
            components.percentEncodedPath = "/\(encodedKey)"
        }
        return components.url!
    }

    private struct WebURL {
        let url: URL
        let hasNoPath: Bool
    }

    // URLSession leaves a default port out of the Host header, and S3Signer signs the port it finds in the URL,
    // so :443 or :80 kept here would sign a Host the server never sees.
    private static func webURL(_ text: String) -> WebURL? {
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty
        else { return nil }
        let path = components.percentEncodedPath
        components.scheme = scheme
        components.host = host.lowercased()
        if components.port == (scheme == "https" ? 443 : 80) {
            components.port = nil
        }
        components.percentEncodedPath = ""
        guard components.query == nil, components.fragment == nil, components.user == nil, let url = components.url else { return nil }
        return WebURL(url: url, hasNoPath: path.isEmpty || path == "/")
    }
}
