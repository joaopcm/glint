import Foundation
import Testing
@testable import LunettaCore

private let fixturesRoot = Bundle.module.resourceURL!.appending(path: "Fixtures/SigV4")

private func caseNames(in suite: String) -> [String] {
    let folder = fixturesRoot.appending(path: suite)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    return names.filter { !$0.hasPrefix(".") }.sorted().map { "\(suite)/\($0)" }
}

private struct Context: Decodable {
    struct Credentials: Decodable {
        let access_key_id: String
        let secret_access_key: String
        let token: String?
    }
    let credentials: Credentials
    let region: String
    let service: String
    let sign_body: Bool
    let timestamp: String
}

private struct RawRequest {
    let method: String
    let target: String
    let headers: [(name: String, value: String)]
    let body: Data
}

private func parseRequest(_ text: String) -> RawRequest {
    let parts = text.components(separatedBy: "\n\n")
    let head = parts[0]
    let body = Data(parts.dropFirst().joined(separator: "\n\n").utf8)
    var lines = head.components(separatedBy: "\n")
    let requestLine = lines.removeFirst()
    let method = String(requestLine.prefix(while: { $0 != " " }))
    let target = String(requestLine.dropFirst(method.count + 1).dropLast(" HTTP/1.1".count))
    var headers: [(name: String, value: String)] = []
    for line in lines where !line.isEmpty {
        if line.first == " " {
            headers[headers.count - 1].value += "\n" + line
        } else {
            let colon = line.firstIndex(of: ":")!
            headers.append((String(line[..<colon]), String(line[line.index(after: colon)...])))
        }
    }
    return RawRequest(method: method, target: target, headers: headers, body: body)
}

private func url(host: String, target: String) -> URL {
    let pieces = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
    let path = pieces[0].addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.union(CharacterSet(charactersIn: "%")))!
    let query = pieces.count > 1 ? "?" + pieces[1].addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.union(CharacterSet(charactersIn: "%")))! : ""
    return URL(string: "https://\(host)\(path)\(query)")!
}

private func read(_ folder: URL, _ name: String) throws -> String {
    try String(contentsOf: folder.appending(path: name), encoding: .utf8)
}

@Test(arguments: caseNames(in: "aws-c-auth") + caseNames(in: "s3-docs"))
func signerMatchesPublishedVector(_ name: String) throws {
    let folder = fixturesRoot.appending(path: name)
    let context = try JSONDecoder().decode(Context.self, from: Data(contentsOf: folder.appending(path: "context.json")))
    let request = parseRequest(try read(folder, "request.txt"))
    let host = request.headers.first { $0.name.lowercased() == "host" }!.value
    let credentials = S3Credentials(
        accessKeyID: context.credentials.access_key_id,
        secretAccessKey: context.credentials.secret_access_key,
        sessionToken: context.credentials.token
    )
    let date = ISO8601DateFormatter().date(from: context.timestamp)!
    let requestURL = url(host: host, target: request.target)
    let payload = PayloadHash.sha256(of: request.body)

    let signed: SignedRequest
    if context.sign_body {
        let headers = Dictionary(uniqueKeysWithValues: request.headers.filter { $0.name.lowercased() != "host" }.map { ($0.name, $0.value) })
        signed = try S3Signer(credentials: credentials, region: context.region, service: context.service)
            .sign(method: request.method, url: requestURL, headers: headers, payload: payload, date: date)
    } else {
        signed = SigV4.sign(
            method: request.method, url: requestURL, headers: request.headers, payloadHash: payload.value,
            credentials: credentials, region: context.region, service: context.service, date: date
        )
    }

    #expect(signed.canonicalRequest == (try read(folder, "header-canonical-request.txt")))
    #expect(signed.stringToSign == (try read(folder, "header-string-to-sign.txt")))
    #expect(signed.authorization.hasSuffix("Signature=\(try read(folder, "header-signature.txt"))"))
    if let expected = try? read(folder, "header-signed-request.txt") {
        let line = expected.components(separatedBy: "\n").first { $0.hasPrefix("Authorization:") }!
        #expect(signed.authorization == String(line.dropFirst("Authorization:".count)))
    }
}

@Test func everyFixtureSuiteHasCases() {
    #expect(caseNames(in: "aws-c-auth").count == 30)
    #expect(caseNames(in: "s3-docs").count == 4)
}
