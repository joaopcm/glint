import Testing
@testable import LunettaCore

@Test func theClickPulseLastsAThumbnailsEnterAndExit() {
    #expect(OverlayStyle.clickPulseDuration == 0.45)
    #expect(OverlayStyle.keysLinger == 1.5)
}
