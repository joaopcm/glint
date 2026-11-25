import Testing
@testable import LunettaCore

@Test func explainsOnlyOnMajorsMeasuredToShowThePrompt() {
    #expect(PickerPromptNotice.shouldExplain(macOSMajor: 15, alreadyExplained: false))
    #expect(PickerPromptNotice.shouldExplain(macOSMajor: 26, alreadyExplained: false))
    #expect(!PickerPromptNotice.shouldExplain(macOSMajor: 27, alreadyExplained: false))
    #expect(!PickerPromptNotice.shouldExplain(macOSMajor: 28, alreadyExplained: false))
}

@Test func explainsOnce() {
    #expect(!PickerPromptNotice.shouldExplain(macOSMajor: 15, alreadyExplained: true))
}

@Test func messageSaysWhatThePromptIsAndThatAllowIsExpected() {
    #expect(PickerPromptNotice.message.contains("private window picker"))
    #expect(PickerPromptNotice.message.contains("Allow"))
}
