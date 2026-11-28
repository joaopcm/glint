import AppKit
import Testing
@testable import Lunetta

@MainActor @Test func theClickPulseHasNoBorderAndLetsTheScreenShowThrough() throws {
    let pulse = ClickRingOverlay.makePulse(centeredAt: CGPoint(x: 100, y: 80))
    #expect(pulse.strokeColor == nil)
    let fill = try #require(pulse.fillColor)
    #expect(fill.alpha <= 0.25)
    #expect(pulse.position == CGPoint(x: 100, y: 80))
    #expect(pulse.bounds.size == CGSize(width: ClickRingOverlay.diameter, height: ClickRingOverlay.diameter))
    #expect(pulse.opacity == 0, "the pulse must stay hidden once its animation ends")
}

@MainActor @Test func theClickPulseSpreadsOutWhileItFades() throws {
    let group = ClickRingOverlay.pulse(reduceMotion: false)
    let animations = try #require(group.animations as? [CABasicAnimation])
    let spread = try #require(animations.first { $0.keyPath == "transform.scale" })
    let fade = try #require(animations.first { $0.keyPath == "opacity" })
    let from = try #require(spread.fromValue as? Double)
    let to = try #require(spread.toValue as? Double)
    #expect(from < to)
    #expect(fade.fromValue as? Double == 1)
    #expect(fade.toValue as? Double == 0)
    #expect(spread.duration == group.duration && fade.duration == group.duration, "both run for the whole pulse, together")
    #expect(group.duration == ThumbnailPresenter.enterDuration + ThumbnailPresenter.exitDuration)
}

@MainActor @Test func reduceMotionKeepsTheClickPulseStillAndOnlyFadesIt() throws {
    let group = ClickRingOverlay.pulse(reduceMotion: true)
    let animations = try #require(group.animations as? [CABasicAnimation])
    #expect(animations.map(\.keyPath) == ["opacity"])
    #expect(animations.first?.toValue as? Double == 0)
}

@MainActor @Test func aPanelShownOutOfTheCaptureIsChromeUntilItHides() {
    let before = Set(CaptureChrome.windowIDs())
    let overlay = ClickRingOverlay()
    let region = CGRect(x: 100, y: 100, width: 200, height: 150)

    overlay.show(over: region, excludedFromCapture: true)
    #expect(Set(CaptureChrome.windowIDs()).subtracting(before).count == 1)
    overlay.hide()
    #expect(Set(CaptureChrome.windowIDs()) == before)

    overlay.show(over: region, excludedFromCapture: false)
    #expect(Set(CaptureChrome.windowIDs()) == before)
    overlay.hide()
}
