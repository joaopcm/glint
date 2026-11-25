import Foundation

public enum StorageProvider: String, CaseIterable, Sendable {
    case aws
    case cloudflareR2
    case backblazeB2
    case minio

    public var name: String {
        switch self {
        case .aws: "AWS S3"
        case .cloudflareR2: "Cloudflare R2"
        case .backblazeB2: "Backblaze B2"
        case .minio: "MinIO"
        }
    }

    public static func hosting(endpoint: String) -> StorageProvider? {
        guard let host = URLComponents(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() else {
            return nil
        }
        if host.hasSuffix(".amazonaws.com") { return .aws }
        if host.hasSuffix(".r2.cloudflarestorage.com") { return .cloudflareR2 }
        if host.hasSuffix(".backblazeb2.com") { return .backblazeB2 }
        return nil
    }

    public func preset(currentRegion: String) -> BucketPreset {
        let region = currentRegion.trimmingCharacters(in: .whitespacesAndNewlines)
        switch self {
        case .aws:
            let region = region.isEmpty || region == "auto" ? "us-east-1" : region
            return BucketPreset(endpoint: "https://s3.\(region).amazonaws.com", region: region, pathStyle: false)
        case .cloudflareR2:
            return BucketPreset(endpoint: "https://<account-id>.r2.cloudflarestorage.com", region: "auto", pathStyle: true)
        case .backblazeB2:
            let region = region.isEmpty || region == "auto" ? "<region>" : region
            return BucketPreset(endpoint: "https://s3.\(region).backblazeb2.com", region: region, pathStyle: true)
        case .minio:
            return BucketPreset(endpoint: "http://localhost:9000", region: "us-east-1", pathStyle: true)
        }
    }
}

public struct BucketPreset: Sendable, Equatable {
    public let endpoint: String
    public let region: String
    public let pathStyle: Bool
}

public struct BucketLocation: Sendable, Equatable {
    public let endpoint: String?
    public let region: String?
    public let bucket: String
    public let pathStyle: Bool
    public let keyPrefix: String

    public init(endpoint: String?, region: String?, bucket: String, pathStyle: Bool, keyPrefix: String) {
        self.endpoint = endpoint
        self.region = region
        self.bucket = bucket
        self.pathStyle = pathStyle
        self.keyPrefix = keyPrefix
    }

    public static func parse(_ text: String) -> BucketLocation? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: text), let scheme = components.scheme?.lowercased() else { return nil }
        let segments = components.path.split(separator: "/").map(String.init)
        if scheme == "s3" {
            guard let bucket = components.host, !bucket.isEmpty else { return nil }
            return BucketLocation(endpoint: nil, region: nil, bucket: bucket, pathStyle: false, keyPrefix: segments.joined(separator: "/"))
        }
        guard scheme == "https" || scheme == "http", let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasSuffix("console.aws.amazon.com") {
            return console(components, host: host, segments: segments)
        }
        let origin = "\(scheme)://\(host)" + (components.port.map { ":\($0)" } ?? "")
        let labels = host.split(separator: ".").map(String.init)

        if host.hasSuffix(".amazonaws.com"), let s3 = labels.firstIndex(where: { $0 == "s3" || $0.hasPrefix("s3-") }) {
            let region = awsRegion(labels, s3Index: s3)
            let endpoint = "\(scheme)://s3.\(region).amazonaws.com"
            if s3 > 0 {
                let bucket = labels[..<s3].joined(separator: ".")
                return BucketLocation(endpoint: endpoint, region: region, bucket: bucket, pathStyle: false, keyPrefix: segments.joined(separator: "/"))
            }
            return pathStyle(endpoint: endpoint, region: region, segments: segments)
        }
        if host.hasSuffix(".r2.cloudflarestorage.com") {
            return pathStyle(endpoint: origin, region: "auto", segments: segments)
        }
        if host.hasSuffix(".backblazeb2.com"), let s3 = labels.firstIndex(of: "s3"), s3 + 1 < labels.count - 2 {
            let region = labels[s3 + 1]
            let endpoint = "\(scheme)://s3.\(region).backblazeb2.com"
            if s3 > 0 {
                let bucket = labels[..<s3].joined(separator: ".")
                return BucketLocation(endpoint: endpoint, region: region, bucket: bucket, pathStyle: false, keyPrefix: segments.joined(separator: "/"))
            }
            return pathStyle(endpoint: endpoint, region: region, segments: segments)
        }
        return pathStyle(endpoint: origin, region: nil, segments: segments)
    }

    private static func pathStyle(endpoint: String, region: String?, segments: [String]) -> BucketLocation? {
        guard let bucket = segments.first else { return nil }
        return BucketLocation(endpoint: endpoint, region: region, bucket: bucket, pathStyle: true, keyPrefix: segments.dropFirst().joined(separator: "/"))
    }

    // Buckets made before 2019 answer at <bucket>.s3.amazonaws.com (us-east-1) and <bucket>.s3-<region>.amazonaws.com.
    // https://docs.aws.amazon.com/AmazonS3/latest/userguide/VirtualHosting.html#VirtualHostingBackwardsCompatibility
    private static func awsRegion(_ labels: [String], s3Index: Int) -> String {
        let s3 = labels[s3Index]
        if s3.hasPrefix("s3-") { return String(s3.dropFirst(3)) }
        let next = labels[s3Index + 1] == "dualstack" ? labels[s3Index + 2] : labels[s3Index + 1]
        return next == "amazonaws" ? "us-east-1" : next
    }

    private static func console(_ components: URLComponents, host: String, segments: [String]) -> BucketLocation? {
        guard let buckets = segments.firstIndex(of: "buckets"), buckets + 1 < segments.count else { return nil }
        let query = components.queryItems ?? []
        let hostRegion = host.split(separator: ".").first.map(String.init).flatMap { $0 == "s3" || $0 == "console" ? nil : $0 }
        let region = query.first { $0.name == "region" }?.value ?? hostRegion ?? "us-east-1"
        let prefix = (query.first { $0.name == "prefix" }?.value ?? "").split(separator: "/").joined(separator: "/")
        return BucketLocation(
            endpoint: "https://s3.\(region).amazonaws.com", region: region,
            bucket: segments[buckets + 1], pathStyle: false, keyPrefix: prefix
        )
    }
}
