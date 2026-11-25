import Foundation
import Testing
@testable import LunettaCore

private let objectURL = "http://localhost:9000/shots/lunetta/lunetta-connection-test-1234.txt"

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [[ConnectionTestStepStatus]] = []

    var snapshots: [[ConnectionTestStepStatus]] { lock.withLock { seen } }

    func record(_ result: ConnectionTestResult) {
        lock.withLock { seen.append(result.steps.map(\.status)) }
    }
}

private func run(_ responses: [Result<S3HTTPResponse, S3TransportError>], progress: ProgressLog? = nil) async -> ConnectionTestResult {
    await ConnectionTest.run(client: client(FakeTransport(responses)), id: "1234") { progress?.record($0) }
}

@Test func connectionTestPutsGetsWithoutKeysThenDeletesTheSameObjectAndLogsEach() async {
    let transport = FakeTransport([ok(200), ok(200), ok(204)])
    let result = await ConnectionTest.run(client: client(transport), id: "1234")

    #expect(transport.requests.map(\.method) == ["PUT", "GET", "DELETE"])
    #expect(transport.requests.map(\.url) == Array(repeating: URL(string: objectURL)!, count: 3))
    #expect(transport.requests[1].headers.isEmpty)
    #expect(result.succeeded)
    #expect(result.publicLink == .opens)
    #expect(result.log == """
        PUT \(objectURL): HTTP 200
        GET \(objectURL) without keys: HTTP 200
        DELETE \(objectURL): HTTP 204
        """)
}

@Test func everyPassingStepIsARowWithItsRequestAndStatus() async {
    let result = await run([ok(200), ok(200), ok(204)])

    #expect(result.steps == [
        ConnectionTestStep(id: .upload, status: .passed, outcome: "These keys can write to shots.",
                           request: "PUT \(objectURL)", httpStatus: 200, log: ["PUT \(objectURL): HTTP 200"]),
        ConnectionTestStep(id: .publicLink, status: .passed, outcome: "Copied links open in a browser.",
                           request: "GET \(objectURL) without keys", httpStatus: 200, log: ["GET \(objectURL) without keys: HTTP 200"]),
        ConnectionTestStep(id: .delete, status: .passed, outcome: "Lunetta can delete what it uploads.",
                           request: "DELETE \(objectURL)", httpStatus: 204, log: ["DELETE \(objectURL): HTTP 204"]),
    ])
    #expect(result.steps.map(\.id.title) == ["Upload a test file", "Copied links open", "Delete the test file"])
}

@Test func rowsUpdateAsEachStepFinishes() async {
    let progress = ProgressLog()
    _ = await run([ok(200), ok(200), ok(204)], progress: progress)

    #expect(progress.snapshots == [
        [.running, .waiting, .waiting],
        [.passed, .running, .waiting],
        [.passed, .passed, .running],
        [.passed, .passed, .passed],
    ])
}

@Test func aBlockedLinkIsAWarningNotAFailureAndTheFileIsStillDeleted() async throws {
    let configuration = try BucketConfiguration(
        endpoint: "https://s3.us-east-2.amazonaws.com", region: "us-east-2", bucket: "lunetta-captures",
        pathStyle: false, keyPrefix: "", publicBaseURL: "https://cdn.example.com/shots"
    )
    let transport = FakeTransport([ok(200), s3Error(403, "AccessDenied", "Access Denied"), ok(204)])
    let s3 = S3Client(configuration: configuration, credentials: testCredentials, transport: transport, now: { fixedDate })
    let result = await ConnectionTest.run(client: s3, id: "1234")

    #expect(transport.requests.map(\.url.absoluteString) == [
        "https://lunetta-captures.s3.us-east-2.amazonaws.com/lunetta-connection-test-1234.txt",
        "https://cdn.example.com/shots/lunetta-connection-test-1234.txt",
        "https://lunetta-captures.s3.us-east-2.amazonaws.com/lunetta-connection-test-1234.txt",
    ])
    #expect(result.succeeded)
    #expect(result.publicLink == .blocked(status: 403, code: "AccessDenied"))
    let link = result[.publicLink]
    #expect(link.status == .warning)
    #expect(link.outcome == "Copied links won't open: the bucket isn't publicly readable (HTTP 403 AccessDenied).")
    #expect(link.request == "GET https://cdn.example.com/shots/lunetta-connection-test-1234.txt without keys")
    #expect(link.httpStatus == 403)
    #expect(link.errorCode == "AccessDenied")
    #expect(link.errorMessage == "Access Denied")
    #expect(result[.delete].status == .passed)
    #expect(result.log.contains("GET https://cdn.example.com/shots/lunetta-connection-test-1234.txt without keys: HTTP 403 AccessDenied"))
}

@Test func aLinkThatAnswersSomethingElseIsAWarningWithThatStatus() async {
    let result = await run([ok(200), s3Error(404, "NoSuchKey", "The specified key does not exist."), ok(204)])
    #expect(result.publicLink == .unexpected(status: 404, code: "NoSuchKey"))
    #expect(result[.publicLink].status == .warning)
    #expect(result[.publicLink].outcome == "Copied links won't open: the link answered HTTP 404 NoSuchKey.")
}

@Test func anUnreachableLinkIsAWarningAndTheFileIsStillDeleted() async {
    let transport = FakeTransport([ok(200), .failure(S3TransportError(reason: "DNS can't find cdn.example.com.")), ok(204)])
    let result = await ConnectionTest.run(client: client(transport), id: "1234")

    #expect(transport.requests.map(\.method) == ["PUT", "GET", "DELETE"])
    #expect(result.succeeded)
    #expect(result.publicLink == .unreachable(reason: "DNS can't find cdn.example.com."))
    #expect(result[.publicLink].status == .warning)
    #expect(result[.publicLink].outcome == "Copied links won't open: DNS can't find cdn.example.com.")
    #expect(result[.publicLink].errorMessage == "DNS can't find cdn.example.com.")
    #expect(result[.publicLink].fix == "Check that localhost answers from this Mac.")
    #expect(result.log.contains("GET \(objectURL) failed: DNS can't find cdn.example.com. (the public link, without keys)"))
}

@Test func aFailedUploadSkipsTheOtherSteps() async {
    let transport = FakeTransport([s3Error(404, "NoSuchBucket", "The specified bucket does not exist")])
    let result = await ConnectionTest.run(client: client(transport), id: "1234")

    #expect(transport.requests.count == 1)
    #expect(!result.succeeded)
    #expect(result.isFinished)
    #expect(result.log == "PUT \(objectURL) failed with HTTP 404. NoSuchBucket: The specified bucket does not exist")
    #expect(result[.upload] == ConnectionTestStep(
        id: .upload, status: .failed, outcome: "There's no bucket named shots at localhost.",
        request: "PUT \(objectURL)", httpStatus: 404, errorCode: "NoSuchBucket", errorMessage: "The specified bucket does not exist",
        fix: "Check the bucket name and the endpoint URL.",
        log: ["PUT \(objectURL) failed with HTTP 404. NoSuchBucket: The specified bucket does not exist"]
    ))
    #expect(result.steps.dropFirst().map(\.status) == [.skipped, .skipped])
    #expect(result.steps.dropFirst().map(\.outcome) == ["Skipped: nothing was uploaded.", "Skipped: nothing was uploaded."])
    #expect(result.steps.dropFirst().allSatisfy { !$0.hasDetails })
}

struct UploadFailureCase: CustomTestStringConvertible, Sendable {
    let status: Int
    let code: String
    let outcome: String
    let fix: String
    var testDescription: String { code }
}

@Test(arguments: [
    UploadFailureCase(status: 403, code: "AccessDenied",
                      outcome: "shots refused the request: these keys don't have s3:PutObject.",
                      fix: "Add s3:PutObject on arn:aws:s3:::shots/lunetta/* to the IAM policy of these keys."),
    UploadFailureCase(status: 403, code: "SignatureDoesNotMatch",
                      outcome: "The secret access key doesn't match the access key ID.",
                      fix: "Paste the secret access key again. It has to be the one created with this access key ID."),
    UploadFailureCase(status: 403, code: "InvalidAccessKeyId",
                      outcome: "The provider doesn't know this access key ID.",
                      fix: "Check the access key ID, and that the endpoint URL belongs to the account that made these keys."),
    UploadFailureCase(status: 301, code: "PermanentRedirect", outcome: "shots isn't in us-east-1.",
                      fix: "Set Region and Endpoint URL to the bucket's region. Pasting the bucket URL from the console fills in both."),
    UploadFailureCase(status: 400, code: "AuthorizationHeaderMalformed", outcome: "shots isn't in us-east-1.",
                      fix: "Set Region and Endpoint URL to the bucket's region. Pasting the bucket URL from the console fills in both."),
    UploadFailureCase(status: 403, code: "RequestTimeTooSkewed", outcome: "This Mac's clock is too far off from the server's.",
                      fix: "Turn on Set time and date automatically in System Settings > General > Date & Time."),
])
func eachS3ErrorOnUploadGetsItsOwnOutcomeAndFix(_ example: UploadFailureCase) async {
    let result = await run([s3Error(example.status, example.code, "from S3")])
    let upload = result[.upload]
    #expect(upload.status == .failed)
    #expect(upload.outcome == example.outcome)
    #expect(upload.fix == example.fix)
    #expect(upload.httpStatus == example.status)
    #expect(upload.errorCode == example.code)
    #expect(upload.errorMessage == "from S3")
}

@Test func anUnknownS3ErrorShowsTheStatusAndCodeWithoutGuessingAFix() async {
    let result = await run([s3Error(503, "SlowDown", "Please reduce your request rate.")])
    #expect(result[.upload].outcome == "shots answered HTTP 503 SlowDown.")
    #expect(result[.upload].fix == nil)
}

@Test func aResponseThatIsntAnS3ErrorPointsAtTheEndpoint() async {
    let result = await run([.success(S3HTTPResponse(status: 405, body: Data("<html>".utf8)))])
    #expect(result[.upload].outcome == "The endpoint answered HTTP 405 without an S3 error.")
    #expect(result[.upload].errorCode == nil)
    #expect(result[.upload].fix == "Check that the endpoint URL points at the S3 API, not a website or a console page.")
}

@Test func anUnreachableEndpointNamesTheHostAndTheReason() async {
    let result = await run([.failure(S3TransportError(reason: "The Internet connection appears to be offline."))])
    #expect(result[.upload].outcome == "Lunetta couldn't reach localhost: The Internet connection appears to be offline.")
    #expect(result[.upload].request == "PUT \(objectURL)")
    #expect(result[.upload].httpStatus == nil)
    #expect(result[.upload].errorMessage == "The Internet connection appears to be offline.")
    #expect(result[.upload].fix == "Check the endpoint URL and this Mac's network connection.")
}

@Test func aDeniedDeleteNamesDeleteObjectAndTheFileLeftBehind() async {
    let result = await run([ok(200), ok(200), s3Error(403, "AccessDenied", "Access Denied")])

    #expect(!result.succeeded)
    #expect(result.publicLink == .opens)
    let delete = result[.delete]
    #expect(delete.status == .failed)
    #expect(delete.outcome == "shots refused the request: these keys don't have s3:DeleteObject. The test file is still in the bucket.")
    #expect(delete.fix == "Add s3:DeleteObject on arn:aws:s3:::shots/lunetta/* to the IAM policy of these keys. Delete it by hand: lunetta/lunetta-connection-test-1234.txt")
    #expect(result.log == """
        PUT \(objectURL): HTTP 200
        GET \(objectURL) without keys: HTTP 200
        DELETE \(objectURL) failed with HTTP 403. AccessDenied: Access Denied
        The test object lunetta/lunetta-connection-test-1234.txt is still in the bucket. Delete it by hand.
        """)
}

@Test func aDeleteThatFailsForAnotherReasonStillSaysToDeleteByHand() async {
    let result = await run([ok(200), ok(200), .failure(S3TransportError(reason: "The network connection was lost."))])
    #expect(result[.delete].fix == "Check the endpoint URL and this Mac's network connection. Delete it by hand: lunetta/lunetta-connection-test-1234.txt")
}

@Test func aSetupProblemFailsTheUploadRowWithoutTouchingTheNetwork() {
    let result = ConnectionTestResult.setupFailed("The endpoint URL not-a-url isn't an http:// or https:// URL with a host.")
    #expect(!result.succeeded)
    #expect(result.isFinished)
    #expect(result[.upload].status == .failed)
    #expect(result[.upload].outcome == "The endpoint URL not-a-url isn't an http:// or https:// URL with a host.")
    #expect(!result[.upload].hasDetails)
    #expect(result.log == "The endpoint URL not-a-url isn't an http:// or https:// URL with a host.")
    #expect(result.steps.dropFirst().map(\.status) == [.skipped, .skipped])
}
