import Testing
@testable import LunettaCore

struct SRGBColorTests {
    @Test func aHashAndSixHexDigitsParse() {
        #expect(SRGBColor(hex: "#FF8000") == SRGBColor(red: 1, green: 128.0 / 255, blue: 0))
        #expect(SRGBColor(hex: "#007aff") == SRGBColor(red: 0, green: 122.0 / 255, blue: 1))
    }

    @Test func anythingElseIsRejected() {
        for invalid in ["", "#", "FF8000", "#FF800", "#FF80000", "#GG8000", "#+F8000", "#-F8000", "# F8000", "#0x8000", "##F8000"] {
            #expect(SRGBColor(hex: invalid) == nil, "\(invalid)")
        }
    }
}
