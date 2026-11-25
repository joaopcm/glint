import Foundation
import Testing
@testable import GlintCore

private let aws = try! BucketConfiguration(
    endpoint: "https://s3.us-east-2.amazonaws.com", region: "us-east-2", bucket: "glint-captures",
    pathStyle: false, keyPrefix: "", publicBaseURL: ""
)

private func awsClient(_ transport: FakeTransport, _ configuration: BucketConfiguration = aws) -> S3Client {
    S3Client(configuration: configuration, credentials: testCredentials, transport: transport, now: { fixedDate })
}

private func body(_ text: String, status: Int = 200) -> Result<S3HTTPResponse, S3TransportError> {
    .success(S3HTTPResponse(status: status, body: Data(text.utf8)))
}

private func json(_ text: String) -> NSDictionary {
    try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! NSDictionary
}

struct BucketURLCase: CustomTestStringConvertible, Sendable {
    let text: String
    let expected: BucketLocation?
    var testDescription: String { text }
}

@Test(arguments: [
    BucketURLCase(text: "https://glint-captures.s3.us-east-2.amazonaws.com", expected: BucketLocation(
        endpoint: "https://s3.us-east-2.amazonaws.com", region: "us-east-2", bucket: "glint-captures", pathStyle: false, keyPrefix: "")),
    BucketURLCase(text: " https://glint-captures.s3.us-east-2.amazonaws.com/shots/2026/ ", expected: BucketLocation(
        endpoint: "https://s3.us-east-2.amazonaws.com", region: "us-east-2", bucket: "glint-captures", pathStyle: false, keyPrefix: "shots/2026")),
    BucketURLCase(text: "https://s3.us-east-2.amazonaws.com/glint-captures/shots", expected: BucketLocation(
        endpoint: "https://s3.us-east-2.amazonaws.com", region: "us-east-2", bucket: "glint-captures", pathStyle: true, keyPrefix: "shots")),
    BucketURLCase(text: "https://glint-captures.s3.amazonaws.com", expected: BucketLocation(
        endpoint: "https://s3.us-east-1.amazonaws.com", region: "us-east-1", bucket: "glint-captures", pathStyle: false, keyPrefix: "")),
    BucketURLCase(text: "https://glint-captures.s3-eu-west-1.amazonaws.com/a", expected: BucketLocation(
        endpoint: "https://s3.eu-west-1.amazonaws.com", region: "eu-west-1", bucket: "glint-captures", pathStyle: false, keyPrefix: "a")),
    BucketURLCase(text: "https://my.dotted.bucket.s3.dualstack.us-east-2.amazonaws.com", expected: BucketLocation(
        endpoint: "https://s3.us-east-2.amazonaws.com", region: "us-east-2", bucket: "my.dotted.bucket", pathStyle: false, keyPrefix: "")),
    BucketURLCase(text: "s3://glint-captures/shots/", expected: BucketLocation(
        endpoint: nil, region: nil, bucket: "glint-captures", pathStyle: false, keyPrefix: "shots")),
    BucketURLCase(text: "https://0123abcd.r2.cloudflarestorage.com/shots/glint", expected: BucketLocation(
        endpoint: "https://0123abcd.r2.cloudflarestorage.com", region: "auto", bucket: "shots", pathStyle: true, keyPrefix: "glint")),
    BucketURLCase(text: "https://0123abcd.eu.r2.cloudflarestorage.com/shots", expected: BucketLocation(
        endpoint: "https://0123abcd.eu.r2.cloudflarestorage.com", region: "auto", bucket: "shots", pathStyle: true, keyPrefix: "")),
    BucketURLCase(text: "https://s3.us-west-004.backblazeb2.com/shots", expected: BucketLocation(
        endpoint: "https://s3.us-west-004.backblazeb2.com", region: "us-west-004", bucket: "shots", pathStyle: true, keyPrefix: "")),
    BucketURLCase(text: "https://shots.s3.eu-central-003.backblazeb2.com/glint", expected: BucketLocation(
        endpoint: "https://s3.eu-central-003.backblazeb2.com", region: "eu-central-003", bucket: "shots", pathStyle: false, keyPrefix: "glint")),
    BucketURLCase(text: "http://localhost:9000/shots/glint", expected: BucketLocation(
        endpoint: "http://localhost:9000", region: nil, bucket: "shots", pathStyle: true, keyPrefix: "glint")),
    BucketURLCase(text: "https://us-east-2.console.aws.amazon.com/s3/buckets/glint-captures?region=us-east-2&bucketType=general&prefix=shots/&showversions=false", expected: BucketLocation(
        endpoint: "https://s3.us-east-2.amazonaws.com", region: "us-east-2", bucket: "glint-captures", pathStyle: false, keyPrefix: "shots")),
    BucketURLCase(text: "https://eu-west-1.console.aws.amazon.com/s3/buckets/glint-captures", expected: BucketLocation(
        endpoint: "https://s3.eu-west-1.amazonaws.com", region: "eu-west-1", bucket: "glint-captures", pathStyle: false, keyPrefix: "")),
    BucketURLCase(text: "glint-captures", expected: nil),
    BucketURLCase(text: "https://s3.us-east-2.amazonaws.com", expected: nil),
    BucketURLCase(text: "ftp://example.com/shots", expected: nil),
    BucketURLCase(text: "https://console.aws.amazon.com/s3/home", expected: nil),
])
func bucketURLsParseIntoTheForm(_ example: BucketURLCase) {
    #expect(BucketLocation.parse(example.text) == example.expected)
}

@Test func theOwnersBucketURLRoundTripsToTheSameObjectHost() throws {
    let location = try #require(BucketLocation.parse("https://glint-captures.s3.us-east-2.amazonaws.com"))
    let configuration = try BucketConfiguration(
        endpoint: location.endpoint!, region: location.region!, bucket: location.bucket,
        pathStyle: location.pathStyle, keyPrefix: location.keyPrefix, publicBaseURL: ""
    )
    #expect(configuration.objectURL(forKey: "a.png").absoluteString == "https://glint-captures.s3.us-east-2.amazonaws.com/a.png")
}

@Test func providersAreRecognizedFromTheEndpoint() {
    #expect(StorageProvider.hosting(endpoint: "https://s3.us-east-2.amazonaws.com") == .aws)
    #expect(StorageProvider.hosting(endpoint: "https://abc.r2.cloudflarestorage.com") == .cloudflareR2)
    #expect(StorageProvider.hosting(endpoint: "https://s3.us-west-004.backblazeb2.com") == .backblazeB2)
    #expect(StorageProvider.hosting(endpoint: "http://localhost:9000") == nil)
    #expect(StorageProvider.hosting(endpoint: "") == nil)
}

@Test func presetsFillTheEndpointRegionAndPathStyle() {
    #expect(StorageProvider.aws.preset(currentRegion: "us-east-2") == BucketPreset(endpoint: "https://s3.us-east-2.amazonaws.com", region: "us-east-2", pathStyle: false))
    #expect(StorageProvider.aws.preset(currentRegion: "auto") == BucketPreset(endpoint: "https://s3.us-east-1.amazonaws.com", region: "us-east-1", pathStyle: false))
    #expect(StorageProvider.cloudflareR2.preset(currentRegion: "us-east-2") == BucketPreset(endpoint: "https://<account-id>.r2.cloudflarestorage.com", region: "auto", pathStyle: true))
    #expect(StorageProvider.backblazeB2.preset(currentRegion: "") == BucketPreset(endpoint: "https://s3.<region>.backblazeb2.com", region: "<region>", pathStyle: true))
    #expect(StorageProvider.minio.preset(currentRegion: "eu-west-1") == BucketPreset(endpoint: "http://localhost:9000", region: "us-east-1", pathStyle: true))
}

@Test func publicReadPolicyMatchesTheOneThatFixedTheOwnersBucket() {
    let fixed = #"{"Version":"2012-10-17","Statement":[{"Sid":"GlintPublicRead","Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::glint-captures/*"}]}"#
    #expect(json(BucketPolicy.publicRead(bucket: "glint-captures", keyPrefix: "")) == json(fixed))
    #expect(BucketPolicy.publicRead(bucket: "glint-captures", keyPrefix: "shots/2026").contains(#""Resource": "arn:aws:s3:::glint-captures/shots/2026/*""#))
}

@Test func uploadPolicyGrantsOnlyPutAndDeleteOnThePrefix() {
    let policy = json(BucketPolicy.uploadAccess(bucket: "glint-captures", keyPrefix: "shots"))
    let statement = (policy["Statement"] as! [NSDictionary])[0]
    #expect(statement["Action"] as? [String] == ["s3:PutObject", "s3:DeleteObject"])
    #expect(statement["Resource"] as? String == "arn:aws:s3:::glint-captures/shots/*")
}

@Test func addingPublicReadKeepsEveryOtherStatement() throws {
    let existing = #"{"Version":"2012-10-17","Statement":[{"Sid":"CloudFront","Effect":"Allow","Principal":{"Service":"cloudfront.amazonaws.com"},"Action":"s3:GetObject","Resource":"arn:aws:s3:::glint-captures/*"}]}"#
    let merged = try #require(try BucketPolicy.addingPublicRead(bucket: "glint-captures", keyPrefix: "", to: existing))
    let statements = json(merged)["Statement"] as! [NSDictionary]
    #expect(statements.map { $0["Sid"] as? String } == ["CloudFront", "GlintPublicRead"])
    #expect(!merged.contains(#"\/"#))
    #expect(try BucketPolicy.addingPublicRead(bucket: "glint-captures", keyPrefix: "", to: merged) == nil)
}

@Test func addingPublicReadReplacesGlintsOwnStatementForAnotherPrefix() throws {
    let old = BucketPolicy.publicRead(bucket: "glint-captures", keyPrefix: "old")
    let merged = try #require(try BucketPolicy.addingPublicRead(bucket: "glint-captures", keyPrefix: "new", to: old))
    let statements = json(merged)["Statement"] as! [NSDictionary]
    #expect(statements.count == 1)
    #expect(statements[0]["Resource"] as? String == "arn:aws:s3:::glint-captures/new/*")
}

@Test func addingPublicReadRefusesAPolicyItCantRead() {
    #expect(throws: BucketPolicyError.notJSON("<html>")) { try BucketPolicy.addingPublicRead(bucket: "b", keyPrefix: "", to: "<html>") }
    #expect(throws: BucketPolicyError.notJSON(#"{"Statement":"x"}"#)) { try BucketPolicy.addingPublicRead(bucket: "b", keyPrefix: "", to: #"{"Statement":"x"}"#) }
}

@Test func putBucketPolicySignsAPutToThePolicySubresourceWithAChecksum() async throws {
    let transport = FakeTransport([ok(204)])
    let policy = BucketPolicy.publicRead(bucket: "glint-captures", keyPrefix: "")
    try await awsClient(transport).putBucketPolicy(policy)

    let request = try #require(transport.requests.first)
    #expect(request.method == "PUT")
    #expect(request.url.absoluteString == "https://glint-captures.s3.us-east-2.amazonaws.com/?policy")
    #expect(request.body == Data(policy.utf8))
    #expect(request.headers["Content-Type"] == "application/json")
    #expect(request.headers["x-amz-checksum-sha256"] == Data(SHA256.hash(Data(policy.utf8))).base64EncodedString())
    #expect(request.headers["x-amz-sdk-checksum-algorithm"] == "SHA256")
    let authorization = try #require(request.headers["Authorization"])
    #expect(authorization.contains("Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-2/s3/aws4_request"))
    #expect(authorization.contains("SignedHeaders=content-type;host;x-amz-checksum-sha256;x-amz-content-sha256;x-amz-date;x-amz-sdk-checksum-algorithm,"))

    let signed = try S3Signer(credentials: testCredentials, region: "us-east-2").sign(
        method: "PUT", url: request.url,
        headers: request.headers.filter { !["Authorization", "x-amz-date", "x-amz-content-sha256"].contains($0.key) },
        payload: .sha256(of: request.body), date: fixedDate
    )
    #expect(signed.canonicalRequest.hasPrefix("PUT\n/\npolicy=\n"))
    #expect(signed.authorization == authorization)
}

@Test func pathStyleBucketSubresourcesGoAfterTheBucketName() async throws {
    let transport = FakeTransport([ok(200)])
    try await client(transport).allowPublicBucketPolicies()
    #expect(transport.requests.first?.url.absoluteString == "http://localhost:9000/shots?publicAccessBlock")
}

@Test func allowPublicBucketPoliciesTurnsOffOnlyThePolicyBlocks() async throws {
    let transport = FakeTransport([ok(200)])
    try await awsClient(transport).allowPublicBucketPolicies()

    let request = try #require(transport.requests.first)
    #expect(request.method == "PUT")
    #expect(request.url.absoluteString == "https://glint-captures.s3.us-east-2.amazonaws.com/?publicAccessBlock")
    #expect(request.headers["Content-Type"] == "application/xml")
    #expect(request.headers["x-amz-checksum-sha256"] != nil)
    #expect(String(decoding: request.body, as: UTF8.self) == """
        <PublicAccessBlockConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">\
        <BlockPublicAcls>true</BlockPublicAcls>\
        <IgnorePublicAcls>true</IgnorePublicAcls>\
        <BlockPublicPolicy>false</BlockPublicPolicy>\
        <RestrictPublicBuckets>false</RestrictPublicBuckets>\
        </PublicAccessBlockConfiguration>
        """)
}

@Test func getBucketPolicyIsNilWhenTheBucketHasNone() async throws {
    let transport = FakeTransport([s3Error(404, "NoSuchBucketPolicy", "The bucket policy does not exist"), body(#"{"Statement":[]}"#)])
    #expect(try await awsClient(transport).getBucketPolicy() == nil)
    #expect(try await awsClient(transport).getBucketPolicy() == #"{"Statement":[]}"#)
    #expect(transport.requests.map(\.method) == ["GET", "GET"])
    #expect(transport.requests[0].url.absoluteString == "https://glint-captures.s3.us-east-2.amazonaws.com/?policy")
}

@Test func makeLinksPublicOpensTheBlocksThenWritesThePolicy() async {
    let transport = FakeTransport([ok(200), s3Error(404, "NoSuchBucketPolicy", "The bucket policy does not exist"), ok(204)])
    let result = await MakeLinksPublic.run(client: awsClient(transport))

    #expect(result.succeeded, "\(result.log)")
    #expect(result.policyToPaste == nil)
    #expect(transport.requests.map { "\($0.method) \($0.url.absoluteString)" } == [
        "PUT https://glint-captures.s3.us-east-2.amazonaws.com/?publicAccessBlock",
        "GET https://glint-captures.s3.us-east-2.amazonaws.com/?policy",
        "PUT https://glint-captures.s3.us-east-2.amazonaws.com/?policy",
    ])
    #expect(transport.requests[2].body == Data(BucketPolicy.publicRead(bucket: "glint-captures", keyPrefix: "").utf8))
    #expect(result.log == """
        PUT https://glint-captures.s3.us-east-2.amazonaws.com/?publicAccessBlock: HTTP 200 (BlockPublicPolicy and RestrictPublicBuckets off, ACL blocks on)
        GET https://glint-captures.s3.us-east-2.amazonaws.com/?policy: HTTP 404 NoSuchBucketPolicy, the bucket has no policy yet
        PUT https://glint-captures.s3.us-east-2.amazonaws.com/?policy: HTTP 204
        """)
}

@Test func makeLinksPublicAddsToAnExistingPolicyInsteadOfReplacingIt() async {
    let existing = #"{"Version":"2012-10-17","Statement":[{"Sid":"Other","Effect":"Deny","Principal":"*","Action":"s3:DeleteBucket","Resource":"arn:aws:s3:::glint-captures"}]}"#
    let transport = FakeTransport([ok(200), body(existing), ok(204)])
    let result = await MakeLinksPublic.run(client: awsClient(transport))

    #expect(result.succeeded)
    let sent = json(String(decoding: transport.requests[2].body, as: UTF8.self))
    #expect((sent["Statement"] as! [NSDictionary]).map { $0["Sid"] as? String } == ["Other", "GlintPublicRead"])
}

@Test func makeLinksPublicSkipsThePutWhenThePolicyAlreadyHasTheStatement() async {
    let transport = FakeTransport([ok(200), body(BucketPolicy.publicRead(bucket: "glint-captures", keyPrefix: ""))])
    let result = await MakeLinksPublic.run(client: awsClient(transport))

    #expect(result.succeeded)
    #expect(transport.requests.count == 2)
    #expect(result.log.hasSuffix("The bucket policy already has the GlintPublicRead statement."))
}

@Test func makeLinksPublicNamesTheMissingPermissionAndOffersThePolicy() async {
    let transport = FakeTransport([s3Error(403, "AccessDenied", "Access Denied")])
    let result = await MakeLinksPublic.run(client: awsClient(transport))

    #expect(!result.succeeded)
    #expect(transport.requests.count == 1)
    #expect(result.policyToPaste == BucketPolicy.publicRead(bucket: "glint-captures", keyPrefix: ""))
    #expect(result.log == """
        PUT https://glint-captures.s3.us-east-2.amazonaws.com/?publicAccessBlock failed with HTTP 403. AccessDenied: Access Denied
        These keys don't have s3:PutBucketPublicAccessBlock on arn:aws:s3:::glint-captures. Add it to their IAM policy, or apply the policy below in the S3 console with an account that has it.
        """)
}

@Test func makeLinksPublicNamesGetBucketPolicyWhenReadingThePolicyIsDenied() async {
    let transport = FakeTransport([ok(200), s3Error(403, "AccessDenied", "Access Denied")])
    let result = await MakeLinksPublic.run(client: awsClient(transport))
    #expect(!result.succeeded)
    #expect(result.log.contains("These keys don't have s3:GetBucketPolicy on arn:aws:s3:::glint-captures."))
}

@Test func makeLinksPublicExplainsAccountLevelBlockPublicAccess() async {
    let message = "User: arn:aws:iam::123456789012:user/glint is not authorized to perform: s3:PutBucketPolicy on resource: \"arn:aws:s3:::glint-captures\" because public policies are blocked by the BlockPublicPolicy block public access setting."
    let transport = FakeTransport([ok(200), s3Error(404, "NoSuchBucketPolicy", "none"), s3Error(403, "AccessDenied", message)])
    let result = await MakeLinksPublic.run(client: awsClient(transport))

    #expect(!result.succeeded)
    #expect(result.log.contains("Block Public Access for the whole AWS account blocks public bucket policies."))
    #expect(result.policyToPaste == BucketPolicy.publicRead(bucket: "glint-captures", keyPrefix: ""))
}

@Test func makeLinksPublicOffersTheMergedPolicyWhenThePutFails() async throws {
    let existing = #"{"Statement":[{"Sid":"Other","Effect":"Allow","Principal":"*","Action":"s3:ListBucket","Resource":"arn:aws:s3:::glint-captures"}]}"#
    let transport = FakeTransport([ok(200), body(existing), s3Error(400, "MalformedPolicy", "Policy has invalid resource")])
    let result = await MakeLinksPublic.run(client: awsClient(transport))

    #expect(!result.succeeded)
    let paste = try #require(result.policyToPaste)
    #expect((json(paste)["Statement"] as! [NSDictionary]).count == 2)
    #expect(result.log.contains("MalformedPolicy: Policy has invalid resource"))
    #expect(result.log.contains("Make Links Public stopped here."))
}

@Test func adviceForAWSHasThePolicyAndTheBlockPublicAccessSteps() {
    let advice = PublicLinkAdvice(for: aws)
    #expect(advice.canMakePublic)
    #expect(advice.bucketPolicy == BucketPolicy.publicRead(bucket: "glint-captures", keyPrefix: ""))
    #expect(advice.steps[0].contains("untick only the two boxes about bucket policies"))
    #expect(advice.steps[1].contains("Block Public Access settings for this account"))
}

@Test func adviceForOtherProvidersNeverMentionsAWS() throws {
    let r2 = try BucketConfiguration(endpoint: "https://abc.r2.cloudflarestorage.com", region: "auto", bucket: "shots", pathStyle: true, keyPrefix: "", publicBaseURL: "")
    let b2 = try BucketConfiguration(endpoint: "https://s3.us-west-004.backblazeb2.com", region: "us-west-004", bucket: "shots", pathStyle: true, keyPrefix: "", publicBaseURL: "")
    let cdn = try BucketConfiguration(endpoint: "https://s3.us-east-2.amazonaws.com", region: "us-east-2", bucket: "shots", pathStyle: false, keyPrefix: "", publicBaseURL: "https://cdn.example.com")
    let advice = [PublicLinkAdvice(for: r2), PublicLinkAdvice(for: b2), PublicLinkAdvice(for: minio), PublicLinkAdvice(for: cdn)]

    #expect(advice.allSatisfy { !$0.canMakePublic })
    #expect(advice.allSatisfy { $0.steps.allSatisfy { !$0.contains("S3 console") && !$0.contains("Block Public Access") } })
    #expect(advice[0].steps[0].contains("R2 > shots > Settings > Public access"))
    #expect(advice[1].steps[0].contains("Files in Bucket are: to Public"))
    #expect(advice[2].steps[0].contains("mc anonymous set download <alias>/shots/glint"))
    #expect(advice[3].steps[0].contains("cdn.example.com"))
}
