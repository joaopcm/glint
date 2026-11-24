import Foundation

public struct SignedRequest: Sendable, Equatable {
    public let headers: [String: String]
    public let authorization: String
    public let canonicalRequest: String
    public let stringToSign: String
}

enum SigV4 {
    private static let algorithm = "AWS4-HMAC-SHA256"

    static func sign(
        method: String,
        url: URL,
        headers: [(name: String, value: String)],
        payloadHash: String,
        credentials: S3Credentials,
        region: String,
        service: String,
        date: Date
    ) -> SignedRequest {
        let timestamp = amzDate(date)
        var headers = headers
        headers.append(("x-amz-date", timestamp))
        if let token = credentials.sessionToken {
            headers.append(("x-amz-security-token", token))
        }

        let canonical = canonicalHeaders(headers)
        let signedHeaders = canonical.map(\.name).joined(separator: ";")
        let canonicalRequest = [
            method,
            canonicalURI(url),
            canonicalQuery(url),
            canonical.map { "\($0.name):\($0.value)\n" }.joined(),
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")

        let scope = "\(timestamp.prefix(8))/\(region)/\(service)/aws4_request"
        let stringToSign = [algorithm, timestamp, scope, SHA256.hash(Array(canonicalRequest.utf8)).hex].joined(separator: "\n")

        var key = Array("AWS4\(credentials.secretAccessKey)".utf8)
        for part in [String(timestamp.prefix(8)), region, service, "aws4_request"] {
            key = SHA256.hmac(key: key, message: Array(part.utf8))
        }
        let signature = SHA256.hmac(key: key, message: Array(stringToSign.utf8)).hex
        let authorization = "\(algorithm) Credential=\(credentials.accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"

        var sent = Dictionary(headers.filter { $0.name.lowercased() != "host" }.map { ($0.name, $0.value) }) { "\($0),\($1)" }
        sent["Authorization"] = authorization
        return SignedRequest(headers: sent, authorization: authorization, canonicalRequest: canonicalRequest, stringToSign: stringToSign)
    }

    private static func amzDate(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02dT%02d%02d%02dZ", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }

    private static func canonicalHeaders(_ headers: [(name: String, value: String)]) -> [(name: String, value: String)] {
        var valuesByName: [String: [String]] = [:]
        for header in headers {
            let value = header.value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            valuesByName[header.name.lowercased(), default: []].append(value)
        }
        return valuesByName.keys.sorted().map { ($0, valuesByName[$0]!.joined(separator: ",")) }
    }

    // S3 signs the path as sent: no dot-segment or slash normalization and a single encoding pass,
    // unlike other services. https://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-header-based-auth.html
    private static func canonicalURI(_ url: URL) -> String {
        let encodedPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
        let path = encodedPath.removingPercentEncoding ?? encodedPath
        return path.isEmpty ? "/" : uriEncode(path, keepingSlashes: true)
    }

    private static func canonicalQuery(_ url: URL) -> String {
        guard let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery else { return "" }
        return query.split(separator: "&")
            .map { pair -> (name: String, value: String) in
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let name = String(parts[0])
                let value = parts.count > 1 ? String(parts[1]) : ""
                return (
                    uriEncode(name.removingPercentEncoding ?? name, keepingSlashes: false),
                    uriEncode(value.removingPercentEncoding ?? value, keepingSlashes: false)
                )
            }
            .sorted { ($0.name, $0.value) < ($1.name, $1.value) }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "&")
    }

    static func uriEncode(_ text: String, keepingSlashes: Bool) -> String {
        var encoded = ""
        for byte in text.utf8 {
            let character = Character(Unicode.Scalar(byte))
            let unreserved = character.isASCII && (character.isLetter || character.isNumber || "-._~".contains(character))
            if unreserved || (keepingSlashes && character == "/") {
                encoded.append(character)
            } else {
                encoded += "%" + [byte].hex.uppercased()
            }
        }
        return encoded
    }
}
