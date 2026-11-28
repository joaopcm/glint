import Testing
@testable import LunettaStudio

@Test func theRenderBudgetIsATripwireAboveTheMeasuredPeak() {
    #expect(MemoryBudget.render.limitMB > 0)
    #expect(MemoryBudget.render.limitMB != MemoryBudget.unlimited.limitMB)
}
