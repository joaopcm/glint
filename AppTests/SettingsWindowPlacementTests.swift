import CoreGraphics
import Testing
@testable import Glint

private let visible = CGRect(x: 0, y: 70, width: 1024, height: 668)

@Test func aWindowAlreadyOnScreenStaysPut() {
    let frame = CGRect(x: 272, y: 95, width: 480, height: 643)
    #expect(SettingsWindowPlacement.fitted(frame, in: visible) == frame)
}

@Test func aWindowGrownPastTheDockMovesUpUntilItsBottomClearsIt() {
    let grown = CGRect(x: 272, y: -170, width: 480, height: 620)
    #expect(SettingsWindowPlacement.fitted(grown, in: visible) == CGRect(x: 272, y: 70, width: 480, height: 620))
}

@Test func aWindowTallerThanTheScreenKeepsItsTitleBarOnScreen() {
    let tall = CGRect(x: 272, y: -300, width: 480, height: 900)
    #expect(SettingsWindowPlacement.fitted(tall, in: visible).maxY == visible.maxY)
}
