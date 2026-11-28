import Testing
@testable import LunettaCore

@Test func tallRuleIsShared() {
    #expect(!TallCapture.isTall(width: 300, height: 900))
    #expect(TallCapture.isTall(width: 300, height: 901))
    #expect(!TallCapture.isTall(width: 400, height: 300))
    #expect(!TallCapture.isTall(width: 1179, height: 2556))
}
