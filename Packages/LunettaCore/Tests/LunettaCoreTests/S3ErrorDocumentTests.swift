import Foundation
import Testing
@testable import LunettaCore

private func xml(_ code: String, _ message: String) -> Data {
    Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <Error><Code>\(code)</Code><Message>\(message)</Message><RequestId>4442587FB7D0A2F9</RequestId></Error>
    """.utf8)
}

@Test func parsesAccessDenied() {
    #expect(S3ErrorDocument(xml: xml("AccessDenied", "Access Denied")) == S3ErrorDocument(code: "AccessDenied", message: "Access Denied"))
}

@Test func parsesNoSuchBucket() {
    #expect(S3ErrorDocument(xml: xml("NoSuchBucket", "The specified bucket does not exist"))?.code == "NoSuchBucket")
}

@Test func parsesSignatureDoesNotMatchWithEscapedCharacters() {
    let document = S3ErrorDocument(xml: xml(
        "SignatureDoesNotMatch",
        "The request signature we calculated does not match the signature you provided. Check your key &amp; signing method. &lt;AWS&gt; &quot;x&quot; &apos;y&apos;"
    ))
    #expect(document?.code == "SignatureDoesNotMatch")
    #expect(document?.message == "The request signature we calculated does not match the signature you provided. Check your key & signing method. <AWS> \"x\" 'y'")
}

@Test func messageIsOptional() {
    #expect(S3ErrorDocument(xml: Data("<Error><Code>InternalError</Code></Error>".utf8)) == S3ErrorDocument(code: "InternalError", message: nil))
}

@Test func nonXMLBodyIsNotAnErrorDocument() {
    #expect(S3ErrorDocument(xml: Data("<html><body><h1>502 Bad Gateway</h1></body></html>".utf8)) == nil)
    #expect(S3ErrorDocument(xml: Data()) == nil)
    #expect(S3ErrorDocument(xml: Data([0xFF, 0xFE, 0x00])) == nil)
}
