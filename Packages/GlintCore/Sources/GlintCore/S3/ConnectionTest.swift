import Foundation

public struct ConnectionTestResult: Sendable, Equatable {
    public let succeeded: Bool
    public let log: String

    public init(succeeded: Bool, log: String) {
        self.succeeded = succeeded
        self.log = log
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
        do {
            let status = try await client.delete(key: key)
            log.append("DELETE \(url): HTTP \(status)")
            return ConnectionTestResult(succeeded: true, log: log.joined(separator: "\n"))
        } catch {
            log.append(error.localizedDescription)
            log.append("The test object \(key) is still in the bucket. Delete it by hand.")
            return ConnectionTestResult(succeeded: false, log: log.joined(separator: "\n"))
        }
    }
}
