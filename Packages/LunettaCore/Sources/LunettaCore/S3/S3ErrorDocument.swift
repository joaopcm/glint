import Foundation

struct S3ErrorDocument: Equatable {
    let code: String
    let message: String?

    init(code: String, message: String?) {
        self.code = code
        self.message = message
    }

    // S3 error bodies are flat <Error><Code/><Message/>…</Error> documents
    // (https://docs.aws.amazon.com/AmazonS3/latest/API/ErrorResponses.html); XMLParser lives outside Foundation on Linux.
    init?(xml: Data) {
        guard let text = String(data: xml, encoding: .utf8), text.contains("<Error>"),
              let code = Self.text(of: "Code", in: text), !code.isEmpty
        else { return nil }
        self.code = code
        self.message = Self.text(of: "Message", in: text)
    }

    private static func text(of element: String, in xml: String) -> String? {
        guard let open = xml.range(of: "<\(element)>"),
              let close = xml.range(of: "</\(element)>", range: open.upperBound..<xml.endIndex)
        else { return nil }
        return String(xml[open.upperBound..<close.lowerBound])
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
