import Foundation
import Testing
@testable import LunettaCore

private func bytes(hex: String) -> [UInt8] {
    var result: [UInt8] = []
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        result.append(UInt8(hex[index..<next], radix: 16)!)
        index = next
    }
    return result
}

private func sha256Hex(_ text: String) -> String {
    SHA256.hash(Array(text.utf8)).hex
}

@Test func sha256MatchesNISTShortMessages() {
    #expect(sha256Hex("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    #expect(sha256Hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    #expect(sha256Hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq") == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    #expect(sha256Hex("abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu") == "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1")
}

@Test func sha256MatchesNISTMillionA() {
    #expect(SHA256.hash([UInt8](repeating: 0x61, count: 1_000_000)).hex == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
}

@Test(arguments: [
    (55, "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318"),
    (56, "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a"),
    (63, "7d3e74a05d7db15bce4ad9ec0658ea98e3f06eeecf16b4c6fff2da457ddc2f34"),
    (64, "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb"),
    (65, "635361c48bb9eab14198e76ea8ab7f1a41685d6ad62aa9146d301d4f17eb0ae0"),
    (119, "31eba51c313a5c08226adf18d4a359cfdfd8d2e816b13f4af952f7ea6584dcfb"),
])
func sha256MatchesShasumAroundPaddingBoundaries(length: Int, expected: String) {
    #expect(SHA256.hash([UInt8](repeating: 0x61, count: length)).hex == expected)
}

@Test(arguments: [
    ("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b", "4869205468657265", "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"),
    ("4a656665", "7768617420646f2079612077616e7420666f72206e6f7468696e673f", "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"),
    ("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", String(repeating: "dd", count: 50), "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe"),
    ("0102030405060708090a0b0c0d0e0f10111213141516171819", String(repeating: "cd", count: 50), "82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b"),
    (String(repeating: "aa", count: 131), "54657374205573696e67204c6172676572205468616e20426c6f636b2d53697a65204b6579202d2048617368204b6579204669727374", "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54"),
    (String(repeating: "aa", count: 131), "5468697320697320612074657374207573696e672061206c6172676572207468616e20626c6f636b2d73697a65206b657920616e642061206c6172676572207468616e20626c6f636b2d73697a6520646174612e20546865206b6579206e6565647320746f20626520686173686564206265666f7265206265696e6720757365642062792074686520484d414320616c676f726974686d2e", "9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2"),
])
func hmacMatchesRFC4231(key: String, data: String, expected: String) {
    #expect(SHA256.hmac(key: bytes(hex: key), message: bytes(hex: data)).hex == expected)
}

@Test func hmacMatchesRFC4231TruncatedCase() {
    let mac = SHA256.hmac(key: bytes(hex: "0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c"), message: Array("Test With Truncation".utf8))
    #expect(Array(mac.prefix(16)).hex == "a3b6167473100ee06e0c796c2955552b")
}

@Test func softwareHasherMatchesAcrossChunkAndDataBoundaries() {
    let payload = [UInt8](repeating: 0x61, count: 1_000_000)
    #expect(SHA256.softwareHash(payload).hex == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    #expect(SHA256.hash(Data(payload)).hex == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")

    var chunked = SHA256.SoftwareHasher()
    var offset = 0
    for step in [1, 7, 56, 63, 64, 65, 129, 512] {
        let end = min(offset + step, payload.count)
        payload[offset..<end].withUnsafeBytes { chunked.update($0) }
        offset = end
    }
    payload[offset...].withUnsafeBytes { chunked.update($0) }
    #expect(chunked.finalize().hex == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")

    let key = bytes(hex: "0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b")
    let msg = bytes(hex: "4869205468657265")
    #expect(SHA256.softwareHMAC(key: key, message: msg).hex == "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
}
