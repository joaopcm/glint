import Foundation

public enum BucketPolicyError: Error, Equatable, LocalizedError {
    case notJSON(String)

    public var errorDescription: String? {
        switch self {
        case .notJSON(let policy):
            "The bucket's current policy isn't a JSON object with a Statement list, so Glint won't touch it:\n\(policy)"
        }
    }
}

public enum BucketPolicy {
    public static let publicReadSid = "GlintPublicRead"
    public static let makePublicActions = ["s3:PutBucketPublicAccessBlock", "s3:GetBucketPolicy", "s3:PutBucketPolicy"]

    public static func objectsARN(bucket: String, keyPrefix: String) -> String {
        keyPrefix.isEmpty ? "arn:aws:s3:::\(bucket)/*" : "arn:aws:s3:::\(bucket)/\(keyPrefix)/*"
    }

    public static func publicRead(bucket: String, keyPrefix: String) -> String {
        """
        {
          "Version": "2012-10-17",
          "Statement": [
            {
              "Sid": "\(publicReadSid)",
              "Effect": "Allow",
              "Principal": "*",
              "Action": "s3:GetObject",
              "Resource": \(quoted(objectsARN(bucket: bucket, keyPrefix: keyPrefix)))
            }
          ]
        }
        """
    }

    public static func uploadAccess(bucket: String, keyPrefix: String) -> String {
        """
        {
          "Version": "2012-10-17",
          "Statement": [
            {
              "Sid": "GlintUpload",
              "Effect": "Allow",
              "Action": ["s3:PutObject", "s3:DeleteObject"],
              "Resource": \(quoted(objectsARN(bucket: bucket, keyPrefix: keyPrefix)))
            }
          ]
        }
        """
    }

    // Glint owns only the statement named publicReadSid: a policy that already has it for another prefix gets it replaced,
    // every other statement is kept as it is.
    public static func addingPublicRead(bucket: String, keyPrefix: String, to existing: String) throws(BucketPolicyError) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(existing.utf8)),
              var policy = object as? [String: Any]
        else { throw .notJSON(existing) }
        var statements: [Any]
        switch policy["Statement"] {
        case let list as [Any]: statements = list
        case let single as [String: Any]: statements = [single]
        case nil: statements = []
        default: throw .notJSON(existing)
        }
        let statement: [String: Any] = [
            "Sid": publicReadSid,
            "Effect": "Allow",
            "Principal": "*",
            "Action": "s3:GetObject",
            "Resource": objectsARN(bucket: bucket, keyPrefix: keyPrefix),
        ]
        if let index = statements.firstIndex(where: { ($0 as? [String: Any])?["Sid"] as? String == publicReadSid }) {
            if NSDictionary(dictionary: statements[index] as! [String: Any]).isEqual(to: statement) { return nil }
            statements[index] = statement
        } else {
            statements.append(statement)
        }
        policy["Statement"] = statements
        policy["Version"] = policy["Version"] ?? "2012-10-17"
        let data = try! JSONSerialization.data(withJSONObject: policy, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    private static func quoted(_ text: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes])
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }
}
