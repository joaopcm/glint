import Foundation
import GlintCore

struct URLSessionS3Transport: S3Transport {
    private let session: URLSession

    init(session: URLSession = URLSession(configuration: Self.sessionConfiguration())) {
        self.session = session
    }

    // With a URL cache, a GET of an object makes URLSession add If-None-Match and If-Modified-Since to the next
    // DELETE of the same URL, and S3 answers that DELETE with 501 NotImplemented (Test Connection on AWS, #96).
    static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }

    func send(_ request: S3HTTPRequest) async throws(S3TransportError) -> S3HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body.isEmpty ? nil : request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw S3TransportError(reason: Self.reason(for: error, host: request.url.host ?? request.url.absoluteString))
        }
        guard let http = response as? HTTPURLResponse else {
            throw S3TransportError(reason: "the server's response isn't HTTP")
        }
        return S3HTTPResponse(status: http.statusCode, body: data)
    }

    // A URLError without userInfo reads only "The operation couldn't be completed. (NSURLErrorDomain error -1009.)"
    // and the system's own text never names the host, so the failures a user can fix get their own words.
    private static func reason(for error: any Error, host: String) -> String {
        guard let urlError = error as? URLError else { return error.localizedDescription }
        let words = switch urlError.code {
        case .notConnectedToInternet: "This Mac is offline."
        case .cannotFindHost, .dnsLookupFailed: "DNS can't find \(host)."
        case .cannotConnectToHost: "\(host) refused the connection."
        case .timedOut: "\(host) didn't answer in time."
        case .appTransportSecurityRequiresSecureConnection: "macOS blocks plain http:// to \(host). Use an https:// endpoint."
        default: urlError.localizedDescription
        }
        return "\(words) (URLError \(urlError.code.rawValue))"
    }
}
