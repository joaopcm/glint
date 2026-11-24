import Foundation

public enum ObjectID {
    public static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
    // 62^16 ≈ 4.8e28 (95 bits). 10,000 guesses/s for a year against a bucket of 1,000,000 captures
    // finds one with probability 3.2e11 × 1e6 / 4.8e28 ≈ 7e-12.
    public static let length = 16

    public static func random() -> String {
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet.randomElement(using: &generator)! })
    }
}

public struct BucketIdentity: Codable, Equatable, Sendable, CustomStringConvertible {
    public let endpoint: URL
    public let bucket: String

    public init(endpoint: URL, bucket: String) {
        self.endpoint = endpoint
        self.bucket = bucket
    }

    public var description: String { "\(bucket) at \(endpoint.absoluteString)" }
}

public struct UploadedCapture: Sendable, Equatable {
    public let key: String
    public let link: URL
    public let bucket: BucketIdentity

    public init(key: String, link: URL, bucket: BucketIdentity) {
        self.key = key
        self.link = link
        self.bucket = bucket
    }
}

public enum UploadError: Error, Equatable, LocalizedError {
    case notConfigured
    case setup(BucketSetupError)
    case unreadable(path: String, reason: String)
    case tooLarge(path: String, bytes: Int)
    case request(S3Error)
    case otherBucket(uploadedTo: BucketIdentity, configured: BucketIdentity)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            "No bucket is set up. Fill in Settings > Upload first."
        case .setup(let error):
            "Settings > Upload has a problem: \(error.localizedDescription)"
        case .unreadable(let path, let reason):
            "Couldn't read \(path): \(reason)"
        case .tooLarge(let path, let bytes):
            "\(path) is \(bytes) bytes. One S3 PUT takes at most \(S3Client.singlePutLimit) bytes (5 GiB), and Glint doesn't split uploads."
        case .request(let error):
            error.localizedDescription
        case .otherBucket(let uploadedTo, let configured):
            "It went to \(uploadedTo), but Settings > Upload points at \(configured) now. "
                + "Glint sent nothing. Point Settings > Upload back at \(uploadedTo) to delete it."
        }
    }
}

extension S3Client {
    // https://docs.aws.amazon.com/AmazonS3/latest/userguide/upload-objects.html: "upload a single object up to 5 GB" in one PUT.
    public static let singlePutLimit = 5 * 1024 * 1024 * 1024

    public func upload(_ file: URL, id: String = ObjectID.random()) async throws(UploadError) -> UploadedCapture {
        let size: NSNumber?
        do {
            size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber
        } catch {
            throw .unreadable(path: file.path, reason: error.localizedDescription)
        }
        guard let bytes = size?.intValue else { throw .unreadable(path: file.path, reason: "the file system reports no size for it") }
        guard bytes <= Self.singlePutLimit else { throw .tooLarge(path: file.path, bytes: bytes) }
        let body: Data
        do {
            body = try Data(contentsOf: file)
        } catch {
            throw .unreadable(path: file.path, reason: error.localizedDescription)
        }
        let ext = file.pathExtension.lowercased()
        let key = configuration.objectKey(forName: ext.isEmpty ? id : "\(id).\(ext)")
        do {
            try await put(key: key, body: body, contentType: Self.contentType(forExtension: ext), contentDisposition: "inline")
        } catch {
            throw .request(error)
        }
        return UploadedCapture(key: key, link: configuration.publicURL(forKey: key), bucket: configuration.identity)
    }

    private static func contentType(forExtension ext: String) -> String {
        switch ext {
        case "png": "image/png"
        case "mp4": "video/mp4"
        default: "application/octet-stream"
        }
    }
}

extension BucketAccess {
    public func upload(_ file: URL) async throws(UploadError) -> UploadedCapture {
        let client: S3Client?
        do {
            client = try self.client()
        } catch {
            throw .setup(error)
        }
        guard let client else { throw .notConfigured }
        return try await client.upload(file)
    }
}
