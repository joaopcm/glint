import Foundation
import Network

/// Stands in for an S3 bucket: answers every request on 127.0.0.1 with 200 and records it.
final class StubS3Server: @unchecked Sendable {
    struct Request {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    struct StartError: Error, CustomStringConvertible {
        let description: String
    }

    /// A tripwire: binding to loopback is immediate, so only a listener that never starts gets here.
    static let startTimeout: TimeInterval = 5

    private let listener: NWListener
    private let queue = DispatchQueue(label: "StubS3Server")
    private let lock = NSLock()
    private var received: [Request] = []
    private var listenError: NWError?

    var port: UInt16 { listener.port?.rawValue ?? 0 }

    var requests: [Request] {
        lock.withLock { received }
    }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                ready.signal()
            case .failed(let error):
                self?.lock.withLock { self?.listenError = error }
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + Self.startTimeout) == .success else {
            listener.cancel()
            throw StartError(description: "the stub S3 server didn't start listening on 127.0.0.1 within \(Self.startTimeout) s")
        }
        if let error = lock.withLock({ listenError }) {
            throw StartError(description: "the stub S3 server can't listen on 127.0.0.1: \(error)")
        }
    }

    func stop() {
        listener.cancel()
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = StubS3Server.parse(buffer) {
                lock.withLock { self.received.append(request) }
                let response = Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private static func parse(_ buffer: Data) -> Request? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        var lines = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = buffer[headerEnd.upperBound...]
        guard body.count >= length else { return nil }
        return Request(method: String(requestLine[0]), path: String(requestLine[1]), headers: headers, body: Data(body.prefix(length)))
    }
}
