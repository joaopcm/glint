import Foundation

public enum PublicLinkCheck: Sendable, Equatable {
    case opens
    case blocked(status: Int, code: String?)
    case unexpected(status: Int, code: String?)
    case unreachable(reason: String)
}

public enum ConnectionTestStepID: String, Sendable, CaseIterable {
    case upload
    case publicLink
    case delete

    public var title: String {
        switch self {
        case .upload: "Upload a test file"
        case .publicLink: "Copied links open"
        case .delete: "Delete the test file"
        }
    }

    var runningOutcome: String {
        switch self {
        case .upload: "Uploading…"
        case .publicLink: "Opening the link without keys…"
        case .delete: "Deleting…"
        }
    }
}

public enum ConnectionTestStepStatus: String, Sendable {
    case waiting
    case running
    case passed
    case warning
    case failed
    case skipped
}

public struct ConnectionTestStep: Sendable, Equatable, Identifiable {
    public let id: ConnectionTestStepID
    public var status: ConnectionTestStepStatus
    public var outcome: String
    public var request: String?
    public var httpStatus: Int?
    public var errorCode: String?
    public var errorMessage: String?
    public var fix: String?
    public var log: [String]

    public init(
        id: ConnectionTestStepID,
        status: ConnectionTestStepStatus,
        outcome: String,
        request: String? = nil,
        httpStatus: Int? = nil,
        errorCode: String? = nil,
        errorMessage: String? = nil,
        fix: String? = nil,
        log: [String] = []
    ) {
        self.id = id
        self.status = status
        self.outcome = outcome
        self.request = request
        self.httpStatus = httpStatus
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.fix = fix
        self.log = log
    }

    public var hasDetails: Bool {
        request != nil || errorMessage != nil || fix != nil
    }
}

public struct ConnectionTestResult: Sendable, Equatable {
    public var steps: [ConnectionTestStep]
    public var publicLink: PublicLinkCheck?

    public init(steps: [ConnectionTestStep], publicLink: PublicLinkCheck? = nil) {
        self.steps = steps
        self.publicLink = publicLink
    }

    public static let waiting = ConnectionTestResult(
        steps: ConnectionTestStepID.allCases.map { ConnectionTestStep(id: $0, status: .waiting, outcome: "Waiting") }
    )

    public static func setupFailed(_ problem: String) -> ConnectionTestResult {
        var result = waiting
        result[.upload] = ConnectionTestStep(id: .upload, status: .failed, outcome: problem, log: [problem])
        result.skipRemaining(because: "Skipped: nothing was uploaded.")
        return result
    }

    public var succeeded: Bool { !steps.contains { $0.status == .failed } }
    public var isFinished: Bool { !steps.contains { $0.status == .waiting || $0.status == .running } }
    public var log: String { steps.flatMap(\.log).joined(separator: "\n") }

    public subscript(id: ConnectionTestStepID) -> ConnectionTestStep {
        get { steps.first { $0.id == id }! }
        set { steps[steps.firstIndex { $0.id == id }!] = newValue }
    }

    mutating func start(_ id: ConnectionTestStepID) {
        self[id].status = .running
        self[id].outcome = id.runningOutcome
    }

    mutating func skipRemaining(because reason: String) {
        for index in steps.indices where steps[index].status == .waiting {
            steps[index].status = .skipped
            steps[index].outcome = reason
        }
    }
}

public enum ConnectionTest {
    public static func run(
        client: S3Client,
        id: String = UUID().uuidString,
        progress: @Sendable (ConnectionTestResult) async -> Void = { _ in }
    ) async -> ConnectionTestResult {
        let configuration = client.configuration
        let key = configuration.objectKey(forName: "glint-connection-test-\(id).txt")
        let url = configuration.objectURL(forKey: key).absoluteString
        var result = ConnectionTestResult.waiting

        result.start(.upload)
        await progress(result)
        do {
            let status = try await client.put(key: key, body: Data("Glint connection test\n".utf8), contentType: "text/plain")
            result[.upload] = ConnectionTestStep(
                id: .upload, status: .passed, outcome: "These keys can write to \(configuration.bucket).",
                request: "PUT \(url)", httpStatus: status, log: ["PUT \(url): HTTP \(status)"]
            )
        } catch {
            result[.upload] = failedStep(.upload, error, action: "s3:PutObject", configuration: configuration)
            result.skipRemaining(because: "Skipped: nothing was uploaded.")
            await progress(result)
            return result
        }

        result.start(.publicLink)
        await progress(result)
        let (publicLinkStep, publicLink) = await checkPublicLink(client: client, key: key)
        result[.publicLink] = publicLinkStep
        result.publicLink = publicLink

        result.start(.delete)
        await progress(result)
        do {
            let status = try await client.delete(key: key)
            result[.delete] = ConnectionTestStep(
                id: .delete, status: .passed, outcome: "Glint can delete what it uploads.",
                request: "DELETE \(url)", httpStatus: status, log: ["DELETE \(url): HTTP \(status)"]
            )
        } catch {
            var step = failedStep(.delete, error, action: "s3:DeleteObject", configuration: configuration)
            step.outcome += " The test file is still in the bucket."
            step.fix = [step.fix, "Delete it by hand: \(key)"].compactMap { $0 }.joined(separator: " ")
            step.log.append("The test object \(key) is still in the bucket. Delete it by hand.")
            result[.delete] = step
        }
        await progress(result)
        return result
    }

    private static func checkPublicLink(client: S3Client, key: String) async -> (ConnectionTestStep, PublicLinkCheck) {
        let link = client.configuration.publicURL(forKey: key)
        let request = "GET \(link.absoluteString) without keys"
        let response: S3HTTPResponse
        do {
            response = try await client.anonymousGet(link)
        } catch {
            let reason: String
            if case .transport(_, _, let transportReason) = error { reason = transportReason } else { reason = error.localizedDescription }
            let step = ConnectionTestStep(
                id: .publicLink, status: .warning, outcome: "Copied links won't open: \(reason)",
                request: request, errorMessage: reason,
                fix: "Check that \(link.host ?? link.absoluteString) answers from this Mac.",
                log: ["\(error.localizedDescription) (the public link, without keys)"]
            )
            return (step, .unreachable(reason: reason))
        }
        let document = S3ErrorDocument(xml: response.body)
        let code = document?.code
        let suffix = code.map { " \($0)" } ?? ""
        let check: PublicLinkCheck
        let outcome: String
        switch response.status {
        case 200..<300:
            check = .opens
            outcome = "Copied links open in a browser."
        case 401, 403:
            check = .blocked(status: response.status, code: code)
            outcome = "Copied links won't open: the bucket isn't publicly readable (HTTP \(response.status)\(suffix))."
        default:
            check = .unexpected(status: response.status, code: code)
            outcome = "Copied links won't open: the link answered HTTP \(response.status)\(suffix)."
        }
        let step = ConnectionTestStep(
            id: .publicLink, status: check == .opens ? .passed : .warning, outcome: outcome,
            request: request, httpStatus: response.status, errorCode: code, errorMessage: document?.message,
            log: ["GET \(link.absoluteString) without keys: HTTP \(response.status)\(suffix)"]
        )
        return (step, check)
    }

    static func failedStep(_ id: ConnectionTestStepID, _ error: S3Error, action: String, configuration: BucketConfiguration) -> ConnectionTestStep {
        var step = ConnectionTestStep(id: id, status: .failed, outcome: "", log: [error.localizedDescription])
        switch error {
        case .service(let method, let url, let status, let code, let message):
            step.request = "\(method) \(url.absoluteString)"
            step.httpStatus = status
            step.errorCode = code
            step.errorMessage = message
            (step.outcome, step.fix) = diagnosis(status: status, code: code, action: action, configuration: configuration)
        case .transport(let method, let url, let reason):
            step.request = "\(method) \(url.absoluteString)"
            step.errorMessage = reason
            step.outcome = "Glint couldn't reach \(url.host ?? url.absoluteString): \(reason)"
            step.fix = "Check the endpoint URL and this Mac's network connection."
        case .signing(let signingError):
            step.outcome = signingError.localizedDescription
        }
        return step
    }

    // Codes from https://docs.aws.amazon.com/AmazonS3/latest/API/ErrorResponses.html#ErrorCodeList; MinIO, R2 and B2 answer
    // with the same codes for these cases.
    private static func diagnosis(status: Int, code: String?, action: String, configuration: BucketConfiguration) -> (String, String?) {
        let bucket = configuration.bucket
        switch code {
        case "AccessDenied":
            return (
                "\(bucket) refused the request: these keys don't have \(action).",
                "Add \(action) on \(BucketPolicy.objectsARN(bucket: bucket, keyPrefix: configuration.keyPrefix)) to the IAM policy of these keys."
            )
        case "SignatureDoesNotMatch":
            return (
                "The secret access key doesn't match the access key ID.",
                "Paste the secret access key again. It has to be the one created with this access key ID."
            )
        case "InvalidAccessKeyId":
            return (
                "The provider doesn't know this access key ID.",
                "Check the access key ID, and that the endpoint URL belongs to the account that made these keys."
            )
        case "NoSuchBucket":
            return (
                "There's no bucket named \(bucket) at \(configuration.endpoint.host ?? configuration.endpoint.absoluteString).",
                "Check the bucket name and the endpoint URL."
            )
        case "PermanentRedirect", "AuthorizationHeaderMalformed", "IllegalLocationConstraintException":
            return (
                "\(bucket) isn't in \(configuration.region).",
                "Set Region and Endpoint URL to the bucket's region. Pasting the bucket URL from the console fills in both."
            )
        case "RequestTimeTooSkewed":
            return (
                "This Mac's clock is too far off from the server's.",
                "Turn on Set time and date automatically in System Settings > General > Date & Time."
            )
        case let code?:
            return ("\(bucket) answered HTTP \(status) \(code).", nil)
        case nil:
            return (
                "The endpoint answered HTTP \(status) without an S3 error.",
                "Check that the endpoint URL points at the S3 API, not a website or a console page."
            )
        }
    }
}
