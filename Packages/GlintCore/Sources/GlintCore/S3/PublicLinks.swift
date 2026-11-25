import Foundation

public struct PublicLinkAdvice: Sendable, Equatable {
    public let steps: [String]
    public let bucketPolicy: String?

    public var canMakePublic: Bool { bucketPolicy != nil }

    public init(for configuration: BucketConfiguration) {
        let bucket = configuration.bucket
        let provider = StorageProvider.hosting(endpoint: configuration.endpoint.absoluteString)
        if let publicBase = configuration.publicBaseURL {
            let host = publicBase.host ?? publicBase.absoluteString
            bucketPolicy = nil
            steps = provider == .cloudflareR2
                ? ["In the Cloudflare dashboard, open R2 > \(bucket) > Settings > Public access and check that the r2.dev URL or the custom domain \(host) is turned on for this bucket."]
                : ["Copied links point at \(host). Check that \(host) serves this bucket without keys, or clear Public base URL to link straight to the bucket."]
            return
        }
        switch provider {
        case .aws:
            bucketPolicy = BucketPolicy.publicRead(bucket: bucket, keyPrefix: configuration.keyPrefix)
            steps = [
                "In the S3 console, open \(bucket) > Permissions > Block public access (bucket settings), click Edit and untick only the two boxes about bucket policies: \"new public bucket or access point policies\" and \"any public bucket or access point policies\".",
                "If the same two boxes are ticked under Block Public Access settings for this account (left sidebar), untick them there too.",
                "Paste this policy in \(bucket) > Permissions > Bucket policy. If the bucket already has one, add the statement to it.",
            ]
        case .cloudflareR2:
            bucketPolicy = nil
            steps = ["R2 never serves objects without keys from the S3 endpoint. In the Cloudflare dashboard, open R2 > \(bucket) > Settings > Public access, turn on the r2.dev URL or connect a custom domain, and put that URL in Public base URL."]
        case .backblazeB2:
            bucketPolicy = nil
            steps = ["In the Backblaze dashboard, open Buckets > \(bucket) > Bucket Settings and set Files in Bucket are: to Public."]
        case .minio, nil:
            bucketPolicy = nil
            let path = configuration.keyPrefix.isEmpty ? bucket : "\(bucket)/\(configuration.keyPrefix)"
            steps = ["Allow anonymous downloads from the bucket. On MinIO: mc anonymous set download <alias>/\(path)"]
        }
    }
}

public struct MakePublicResult: Sendable, Equatable {
    public let succeeded: Bool
    public let log: String
    public let policyToPaste: String?
}

public enum MakeLinksPublic {
    public static func run(client: S3Client) async -> MakePublicResult {
        let configuration = client.configuration
        let bucketARN = "arn:aws:s3:::\(configuration.bucket)"
        let ownPolicy = BucketPolicy.publicRead(bucket: configuration.bucket, keyPrefix: configuration.keyPrefix)
        var log: [String] = []

        func fail(_ error: S3Error, action: String, paste: String = ownPolicy) -> MakePublicResult {
            log.append(error.localizedDescription)
            log.append(explanation(of: error, action: action, resource: bucketARN))
            return MakePublicResult(succeeded: false, log: log.joined(separator: "\n"), policyToPaste: paste)
        }

        let accessBlockURL = configuration.bucketURL(subresource: "publicAccessBlock").absoluteString
        do {
            let status = try await client.allowPublicBucketPolicies()
            log.append("PUT \(accessBlockURL): HTTP \(status) (BlockPublicPolicy and RestrictPublicBuckets off, ACL blocks on)")
        } catch {
            return fail(error, action: "s3:PutBucketPublicAccessBlock")
        }

        let policyURL = configuration.bucketURL(subresource: "policy").absoluteString
        let existing: String?
        do {
            existing = try await client.getBucketPolicy()
            log.append("GET \(policyURL): " + (existing == nil ? "HTTP 404 NoSuchBucketPolicy, the bucket has no policy yet" : "HTTP 200"))
        } catch {
            return fail(error, action: "s3:GetBucketPolicy")
        }

        let policy: String
        if let existing {
            let merged: String?
            do throws(BucketPolicyError) {
                merged = try BucketPolicy.addingPublicRead(bucket: configuration.bucket, keyPrefix: configuration.keyPrefix, to: existing)
            } catch {
                log.append(error.localizedDescription)
                return MakePublicResult(succeeded: false, log: log.joined(separator: "\n"), policyToPaste: ownPolicy)
            }
            guard let merged else {
                log.append("The bucket policy already has the \(BucketPolicy.publicReadSid) statement.")
                return MakePublicResult(succeeded: true, log: log.joined(separator: "\n"), policyToPaste: nil)
            }
            policy = merged
        } else {
            policy = ownPolicy
        }

        do {
            let status = try await client.putBucketPolicy(policy)
            log.append("PUT \(policyURL): HTTP \(status)")
            return MakePublicResult(succeeded: true, log: log.joined(separator: "\n"), policyToPaste: nil)
        } catch {
            return fail(error, action: "s3:PutBucketPolicy", paste: policy)
        }
    }

    // With account-level Block Public Access on, S3 refuses a public policy with a plain AccessDenied whose message names
    // the setting: "...because public policies are blocked by the BlockPublicPolicy block public access setting."
    // https://docs.aws.amazon.com/AmazonS3/latest/userguide/access-control-block-public-access.html
    static func explanation(of error: S3Error, action: String, resource: String) -> String {
        guard case .service(_, _, 403, "AccessDenied", let message) = error else {
            return "Make Links Public stopped here. Copy the policy below and apply it in the S3 console instead."
        }
        if message?.contains("BlockPublicPolicy") == true {
            return "Block Public Access for the whole AWS account blocks public bucket policies. In the S3 console, open Block Public Access settings for this account, untick the two boxes about bucket policies, then click Make Links Public again."
        }
        return "These keys don't have \(action) on \(resource). Add it to their IAM policy, or apply the policy below in the S3 console with an account that has it."
    }
}
