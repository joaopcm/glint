import Testing
@testable import LunettaCore

/// 10 per character, so widths are easy to follow.
private func measure(_ text: String) -> Double { Double(text.count) * 10 }

@Test func textThatFitsStaysWhole() {
    #expect(TextTruncation.tail("Desk Mic", fitting: 80, measure: measure) == "Desk Mic")
}

@Test func longTextKeepsTheMostThatFitsWithAnEllipsis() {
    let truncated = TextTruncation.tail("MacBook Pro Microphone", fitting: 100, measure: measure)
    #expect(truncated == "MacBook P…")
    #expect(measure(truncated) <= 100)
}

@Test func anEllipsisNeverFollowsASpace() {
    #expect(TextTruncation.tail("MacBook Pro Microphone", fitting: 90, measure: measure) == "MacBook…")
}

@Test func noRoomLeavesJustTheEllipsis() {
    #expect(TextTruncation.tail("Microphone", fitting: 5, measure: measure) == "…")
}
