import Foundation

public struct SignedRequest: Sendable, Equatable {
    public let headers: [String: String]
    public let authorization: String
    public let canonicalRequest: String
    public let stringToSign: String
}

enum SigV4 {
    private static let algorithm = "AWS4-HMAC-SHA256"
    private static let upperHexDigits = ContiguousArray("0123456789ABCDEF".utf8)
    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

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
        sign(
            method: method,
            components: URLComponents(url: url, resolvingAgainstBaseURL: false),
            headers: headers,
            payloadHash: payloadHash,
            credentials: credentials,
            region: region,
            service: service,
            date: date
        )
    }

    static func sign(
        method: String,
        components: URLComponents?,
        headers: [(name: String, value: String)],
        payloadHash: String,
        credentials: S3Credentials,
        region: String,
        service: String,
        date: Date
    ) -> SignedRequest {
        let timestamp = amzDate(date)
        var headers = headers
        headers.reserveCapacity(headers.count + 2)
        headers.append(("x-amz-date", timestamp))
        if let token = credentials.sessionToken {
            headers.append(("x-amz-security-token", token))
        }

        let canonical = canonicalHeaders(headers)
        let signedHeaders = canonical.map(\.name).joined(separator: ";")
        let canonicalRequest = [
            method,
            canonicalURI(components),
            canonicalQuery(components),
            canonical.map { "\($0.name):\($0.value)\n" }.joined(),
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")

        let dateStamp = String(timestamp.prefix(8))
        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = [algorithm, timestamp, scope, SHA256.hash(canonicalRequest.utf8).hex].joined(separator: "\n")

        var key = Array("AWS4\(credentials.secretAccessKey)".utf8)
        key = SHA256.hmac(key: key, message: dateStamp.utf8)
        key = SHA256.hmac(key: key, message: region.utf8)
        key = SHA256.hmac(key: key, message: service.utf8)
        key = SHA256.hmac(key: key, message: "aws4_request".utf8)
        let signature = SHA256.hmac(key: key, message: stringToSign.utf8).hex
        let authorization = "\(algorithm) Credential=\(credentials.accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"

        var sent = Dictionary(minimumCapacity: headers.count + 1) as [String: String]
        for header in headers where header.name.caseInsensitiveCompare("host") != .orderedSame {
            if let existing = sent[header.name] {
                sent[header.name] = "\(existing),\(header.value)"
            } else {
                sent[header.name] = header.value
            }
        }
        sent["Authorization"] = authorization
        return SignedRequest(headers: sent, authorization: authorization, canonicalRequest: canonicalRequest, stringToSign: stringToSign)
    }

    private static func amzDate(_ date: Date) -> String {
        let c = utcCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = c.year!, month = c.month!, day = c.day!, hour = c.hour!, minute = c.minute!, second = c.second!
        guard (0...9999).contains(year) else {
            return String(format: "%04d%02d%02dT%02d%02d%02dZ", year, month, day, hour, minute, second)
        }
        return String(unsafeUninitializedCapacity: 16) { out in
            writeFourDigits(year, to: out, at: 0)
            writeTwoDigits(month, to: out, at: 4)
            writeTwoDigits(day, to: out, at: 6)
            out[8] = 0x54 // 'T'
            writeTwoDigits(hour, to: out, at: 9)
            writeTwoDigits(minute, to: out, at: 11)
            writeTwoDigits(second, to: out, at: 13)
            out[15] = 0x5A // 'Z'
            return 16
        }
    }

    private static func canonicalHeaders(_ headers: [(name: String, value: String)]) -> [(name: String, value: String)] {
        var valuesByName: [String: [String]] = Dictionary(minimumCapacity: headers.count)
        for header in headers {
            let value = header.value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            valuesByName[header.name.lowercased(), default: []].append(value)
        }
        return valuesByName.keys.sorted().map { ($0, valuesByName[$0]!.joined(separator: ",")) }
    }

    // S3 signs the path as sent: no dot-segment or slash normalization and a single encoding pass,
    // unlike other services. https://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-header-based-auth.html
    private static func canonicalURI(_ components: URLComponents?) -> String {
        let encodedPath = components?.percentEncodedPath ?? ""
        let path = encodedPath.removingPercentEncoding ?? encodedPath
        return path.isEmpty ? "/" : uriEncode(path, keepingSlashes: true)
    }

    private static func canonicalQuery(_ components: URLComponents?) -> String {
        guard let query = components?.percentEncodedQuery else { return "" }
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
        let utf8 = text.utf8
        guard !utf8.isEmpty else { return "" }
        return upperHexDigits.withUnsafeBufferPointer { hex in
            String(unsafeUninitializedCapacity: utf8.count * 3) { out in
                var index = 0
                for byte in utf8 {
                    let unreserved = (byte >= 0x41 && byte <= 0x5A)
                        || (byte >= 0x61 && byte <= 0x7A)
                        || (byte >= 0x30 && byte <= 0x39)
                        || byte == 0x2D || byte == 0x2E || byte == 0x5F || byte == 0x7E
                    if unreserved || (keepingSlashes && byte == 0x2F) {
                        out[index] = byte
                        index += 1
                    } else {
                        out[index] = 0x25
                        out[index + 1] = hex[Int(byte >> 4)]
                        out[index + 2] = hex[Int(byte & 0x0f)]
                        index += 3
                    }
                }
                return index
            }
        }
    }

    @inline(__always)
    static func writeFourDigits(_ value: Int, to out: UnsafeMutableBufferPointer<UInt8>, at offset: Int) {
        writeTwoDigits(value / 100, to: out, at: offset)
        writeTwoDigits(value % 100, to: out, at: offset + 2)
    }

    @inline(__always)
    static func writeTwoDigits(_ value: Int, to out: UnsafeMutableBufferPointer<UInt8>, at offset: Int) {
        out[offset] = 0x30 &+ UInt8(value / 10)
        out[offset + 1] = 0x30 &+ UInt8(value % 10)
    }
}
