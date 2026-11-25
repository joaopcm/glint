import Foundation
import Testing
@testable import LunettaCore

private let credentials = S3Credentials(accessKeyID: "AKIAIOSFODNN7EXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
private let date = ISO8601DateFormatter().date(from: "2013-05-24T00:00:00Z")!
private let signer = S3Signer(credentials: credentials, region: "us-east-1")

@Test func returnsEveryHeaderToSendExceptHost() throws {
    let url = URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!
    let signed = try signer.sign(method: "GET", url: url, headers: ["Range": "bytes=0-9"], payload: .sha256(of: Data()), date: date)
    #expect(signed.headers == [
        "Range": "bytes=0-9",
        "x-amz-content-sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        "x-amz-date": "20130524T000000Z",
        "Authorization": signed.authorization,
    ])
    #expect(signed.authorization == "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
}

@Test func unsignedPayloadIsSignedAsTheLiteral() throws {
    let url = URL(string: "https://examplebucket.s3.amazonaws.com/a.png")!
    let signed = try signer.sign(method: "PUT", url: url, payload: .unsigned, date: date)
    #expect(signed.headers["x-amz-content-sha256"] == "UNSIGNED-PAYLOAD")
    #expect(signed.canonicalRequest.hasSuffix("\nUNSIGNED-PAYLOAD"))
}

@Test func pathStyleURLWithPortSignsHostWithPortAndBucketInPath() throws {
    let url = URL(string: "http://localhost:9000/examplebucket/shots/a%20b.png")!
    let signed = try signer.sign(method: "PUT", url: url, payload: .unsigned, date: date)
    let lines = signed.canonicalRequest.components(separatedBy: "\n")
    #expect(lines[1] == "/examplebucket/shots/a%20b.png")
    #expect(lines.contains("host:localhost:9000"))
}

@Test func callerHostHeaderIsReplacedByTheURLHost() throws {
    let url = URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!
    let withHost = try signer.sign(method: "GET", url: url, headers: ["Host": "elsewhere.example.com"], payload: .unsigned, date: date)
    let without = try signer.sign(method: "GET", url: url, payload: .unsigned, date: date)
    #expect(withHost == without)
}

@Test func sessionTokenIsSentAndSigned() throws {
    let temporary = S3Credentials(accessKeyID: "AKIAIOSFODNN7EXAMPLE", secretAccessKey: "secret", sessionToken: "token123")
    let url = URL(string: "https://examplebucket.s3.amazonaws.com/a.png")!
    let signed = try S3Signer(credentials: temporary, region: "eu-west-1").sign(method: "DELETE", url: url, payload: .unsigned, date: date)
    #expect(signed.headers["x-amz-security-token"] == "token123")
    #expect(signed.authorization.contains("SignedHeaders=host;x-amz-content-sha256;x-amz-date;x-amz-security-token,"))
    #expect(signed.authorization.contains("/20130524/eu-west-1/s3/aws4_request,"))
}

@Test func urlWithoutHostFailsNamingTheURL() {
    let url = URL(string: "/examplebucket/a.png")!
    #expect(throws: S3SigningError.urlHasNoHost(url)) {
        try signer.sign(method: "PUT", url: url, payload: .unsigned, date: date)
    }
    #expect(S3SigningError.urlHasNoHost(url).localizedDescription == "Can't sign the request to /examplebucket/a.png: the URL has no host, so there is no endpoint to sign for.")
}
