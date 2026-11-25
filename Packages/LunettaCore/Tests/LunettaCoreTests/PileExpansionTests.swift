import Testing
@testable import LunettaCore

private let builtIn = "built-in"
private let external = "external"

@Test func expandingOnePileLeavesTheOtherDisplayCollapsed() {
    var piles = PileExpansion<String>()
    piles.expand(on: builtIn)

    #expect(piles.isExpanded(on: builtIn))
    #expect(!piles.isExpanded(on: external))
}

@Test func collapsingOnePileKeepsTheOtherExpanded() {
    var piles = PileExpansion<String>()
    piles.expand(on: builtIn)
    piles.expand(on: external)
    piles.collapse(on: external)

    #expect(piles.isExpanded(on: builtIn))
    #expect(!piles.isExpanded(on: external))
}

@Test func onlyThePileUnderThePointerStaysOpen() {
    var piles = PileExpansion<String>()
    piles.expand(on: builtIn)
    piles.expand(on: external)

    #expect(piles.pilesToFold(pointerOver: builtIn) == [external])
    #expect(piles.pilesToFold(pointerOver: external) == [builtIn])
    #expect(piles.pilesToFold(pointerOver: nil) == [builtIn, external])
}

@Test func collapsedPilesNeverFold() {
    var piles = PileExpansion<String>()
    #expect(piles.pilesToFold(pointerOver: nil).isEmpty)

    piles.expand(on: builtIn)
    #expect(piles.pilesToFold(pointerOver: builtIn).isEmpty)
}
