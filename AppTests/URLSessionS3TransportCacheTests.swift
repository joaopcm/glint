import Foundation
import LunettaCore
import Network
import Testing
@testable import Lunetta

private final class LoopbackHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "LoopbackHTTPServer")
    private let lock = NSLock()
    private var heads: [String] = []

    var requestHeads: [String] { lock.withLock { heads } }
    var port: UInt16 { listener.port?.rawValue ?? 0 }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: self!.queue)
            self?.receive(connection, buffer: Data())
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
    }

    func stop() { listener.cancel() }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, _ in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if !isComplete { self.receive(connection, buffer: buffer) }
                return
            }
            let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
            lock.withLock { heads.append(head) }
            let response = head.hasPrefix("GET")
                ? "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nETag: \"abc\"\r\nLast-Modified: Wed, 25 Nov 2026 12:00:00 GMT\r\nContent-Length: 8\r\nConnection: close\r\n\r\nlunetta\n"
                : "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

@Suite struct URLSessionS3TransportCacheTests {
    @Test func deleteAfterAGetOfTheSameURLCarriesNoConditionalHeaders() async throws {
        let server = try LoopbackHTTPServer()
        defer { server.stop() }
        let url = try #require(URL(string: "http://127.0.0.1:\(server.port)/lunetta-connection-test.txt"))
        let transport = URLSessionS3Transport()

        _ = try await transport.send(S3HTTPRequest(method: "GET", url: url, headers: [:], body: Data()))
        _ = try await transport.send(S3HTTPRequest(method: "DELETE", url: url, headers: ["Authorization": "AWS4-HMAC-SHA256 test"], body: Data()))

        let delete = try #require(server.requestHeads.last)
        #expect(delete.hasPrefix("DELETE "))
        #expect(!delete.lowercased().contains("if-none-match"), "DELETE sent conditional headers:\n\(delete)")
        #expect(!delete.lowercased().contains("if-modified-since"), "DELETE sent conditional headers:\n\(delete)")
    }
}
