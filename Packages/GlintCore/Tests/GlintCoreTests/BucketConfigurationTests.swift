import Foundation
import Testing
@testable import GlintCore

private func configuration(
    endpoint: String = "https://s3.us-east-1.amazonaws.com",
    region: String = "us-east-1",
    bucket: String = "shots",
    pathStyle: Bool = false,
    keyPrefix: String = "",
    publicBaseURL: String = ""
) throws(BucketSetupError) -> BucketConfiguration {
    try BucketConfiguration(
        endpoint: endpoint, region: region, bucket: bucket,
        pathStyle: pathStyle, keyPrefix: keyPrefix, publicBaseURL: publicBaseURL
    )
}

@Test func virtualHostedPutsTheBucketInTheHost() throws {
    let url = try configuration().objectURL(forKey: "a.png")
    #expect(url.absoluteString == "https://shots.s3.us-east-1.amazonaws.com/a.png")
}

@Test func pathStylePutsTheBucketInThePathAndKeepsTheMinIOPort() throws {
    let url = try configuration(endpoint: "http://localhost:9000", pathStyle: true).objectURL(forKey: "a.png")
    #expect(url.absoluteString == "http://localhost:9000/shots/a.png")
}

@Test func defaultPortsAreDroppedSoTheSignedHostMatchesWhatURLSessionSends() throws {
    #expect(try configuration(endpoint: "https://S3.Example.com:443/").endpoint.absoluteString == "https://s3.example.com")
    #expect(try configuration(endpoint: "http://minio.lan:80", pathStyle: true).endpoint.absoluteString == "http://minio.lan")
    #expect(try configuration(endpoint: "https://minio.lan:9000").endpoint.absoluteString == "https://minio.lan:9000")
}

@Test func endpointWhitespaceIsTrimmed() throws {
    #expect(try configuration(endpoint: "  https://s3.example.com \n").endpoint.absoluteString == "https://s3.example.com")
}

@Test func keyPrefixIsAFolderWithoutStraySlashes() throws {
    #expect(try configuration(keyPrefix: "/shots/2026/").objectKey(forName: "a.png") == "shots/2026/a.png")
    #expect(try configuration(keyPrefix: "shots").objectKey(forName: "a.png") == "shots/a.png")
    #expect(try configuration().objectKey(forName: "a.png") == "a.png")
}

@Test func keysAreEncodedTheWaySigV4SignsThem() throws {
    let url = try configuration(endpoint: "http://localhost:9000", pathStyle: true).objectURL(forKey: "my shots/ü+1.png")
    #expect(url.absoluteString == "http://localhost:9000/shots/my%20shots/%C3%BC%2B1.png")
    let signer = S3Signer(credentials: S3Credentials(accessKeyID: "a", secretAccessKey: "b"), region: "us-east-1")
    let signed = try signer.sign(method: "PUT", url: url, payload: .unsigned, date: Date(timeIntervalSince1970: 0))
    #expect(signed.canonicalRequest.components(separatedBy: "\n")[1] == "/shots/my%20shots/%C3%BC%2B1.png")
}

@Test func publicBaseURLIsOptionalButMustBeAWebURL() throws {
    #expect(try configuration().publicBaseURL == nil)
    #expect(try configuration(publicBaseURL: "https://shots.example.com/").publicBaseURL?.absoluteString == "https://shots.example.com")
    #expect(throws: BucketSetupError.publicBaseURLInvalid("shots.example.com")) { try configuration(publicBaseURL: "shots.example.com") }
}

@Test func everyMissingOrBadFieldIsNamed() {
    #expect(throws: BucketSetupError.endpointMissing) { try configuration(endpoint: " ") }
    #expect(throws: BucketSetupError.endpointInvalid("s3.example.com")) { try configuration(endpoint: "s3.example.com") }
    #expect(throws: BucketSetupError.endpointInvalid("ftp://s3.example.com")) { try configuration(endpoint: "ftp://s3.example.com") }
    #expect(throws: BucketSetupError.endpointHasPath("https://s3.example.com/shots")) { try configuration(endpoint: "https://s3.example.com/shots") }
    #expect(throws: BucketSetupError.regionMissing) { try configuration(region: "") }
    #expect(throws: BucketSetupError.bucketMissing) { try configuration(bucket: "") }
    #expect(throws: BucketSetupError.bucketInvalid("a/b")) { try configuration(bucket: "a/b") }
}

@Test func setupErrorsSayWhatToFix() {
    #expect(BucketSetupError.endpointHasPath("https://s3.example.com/shots").localizedDescription
        == "The endpoint URL https://s3.example.com/shots has a path. Put only the scheme and host there (https://s3.example.com) and the bucket name in Bucket.")
    #expect(BucketSetupError.regionMissing.localizedDescription
        == "Region is empty. Use the bucket's region (us-east-1 on AWS, auto on Cloudflare R2).")
    #expect(BucketSetupError.secretMissing.localizedDescription == "Secret access key is empty.")
}
