import Foundation

public enum PublicLinkCheck: Sendable, Equatable {
    case opens
    case blocked(status: Int, code: String?)
    case unexpected(status: Int, code: String?)
    case unreachable(reason: String)
}

public struct ConnectionTestResult: Sendable, Equatable {
    public let succeeded: Bool
    public let log: String
    public let publicLink: PublicLinkCheck?

    public init(succeeded: Bool, log: String, publicLink: PublicLinkCheck? = nil) {
        self.succeeded = succeeded
        self.log = log
        self.publicLink = publicLink
    }
}

public enum ConnectionTest {
    public static func run(client: S3Client, id: String = UUID().uuidString) async -> ConnectionTestResult {
        let key = client.configuration.objectKey(forName: "glint-connection-test-\(id).txt")
        let url = client.configuration.objectURL(forKey: key).absoluteString
        var log: [String] = []
        do {
            let status = try await client.put(key: key, body: Data("Glint connection test\n".utf8), contentType: "text/plain")
            log.append("PUT \(url): HTTP \(status)")
        } catch {
            log.append(error.localizedDescription)
            return ConnectionTestResult(succeeded: false, log: log.joined(separator: "\n"))
        }
        let publicLink = await checkPublicLink(client: client, key: key, log: &log)
        do {
            let status = try await client.delete(key: key)
            log.append("DELETE \(url): HTTP \(status)")
            return ConnectionTestResult(succeeded: true, log: log.joined(separator: "\n"), publicLink: publicLink)
        } catch {
            log.append(error.localizedDescription)
            log.append("The test object \(key) is still in the bucket. Delete it by hand.")
            return ConnectionTestResult(succeeded: false, log: log.joined(separator: "\n"), publicLink: publicLink)
        }
    }

    private static func checkPublicLink(client: S3Client, key: String, log: inout [String]) async -> PublicLinkCheck {
        let link = client.configuration.publicURL(forKey: key)
        let response: S3HTTPResponse
        do {
            response = try await client.anonymousGet(link)
        } catch {
            log.append("\(error.localizedDescription) (the public link, without keys)")
            if case .transport(_, _, let reason) = error { return .unreachable(reason: reason) }
            return .unreachable(reason: error.localizedDescription)
        }
        let code = S3ErrorDocument(xml: response.body)?.code
        log.append("GET \(link.absoluteString) without keys: HTTP \(response.status)" + (code.map { " \($0)" } ?? ""))
        switch response.status {
        case 200..<300: return .opens
        case 401, 403: return .blocked(status: response.status, code: code)
        default: return .unexpected(status: response.status, code: code)
        }
    }
}
