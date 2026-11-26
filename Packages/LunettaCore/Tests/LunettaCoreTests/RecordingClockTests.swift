import Foundation
import Testing
@testable import LunettaCore

private let t0 = Date(timeIntervalSince1970: 1_795_000_000)

@Test func aNewClockReadsZeroAndIsStopped() {
    let clock = RecordingClock()
    #expect(!clock.isRunning)
    #expect(clock.elapsed(at: t0) == 0)
}

@Test func theClockCountsOnlyWhileRunning() {
    var clock = RecordingClock()
    clock.start(at: t0)
    #expect(clock.elapsed(at: t0 + 5) == 5)
    clock.pause(at: t0 + 5)
    #expect(clock.elapsed(at: t0 + 60) == 5)
    clock.start(at: t0 + 60)
    #expect(clock.elapsed(at: t0 + 62.5) == 7.5)
}

@Test func startingARunningClockKeepsItsStart() {
    var clock = RecordingClock()
    clock.start(at: t0)
    clock.start(at: t0 + 3)
    #expect(clock.elapsed(at: t0 + 4) == 4)
}

@Test func pausingTwiceBanksTheTimeOnce() {
    var clock = RecordingClock()
    clock.start(at: t0)
    clock.pause(at: t0 + 2)
    clock.pause(at: t0 + 9)
    #expect(clock.elapsed(at: t0 + 20) == 2)
}

@Test func aClockReadBeforeItsStartNeverGoesNegative() {
    var clock = RecordingClock()
    clock.start(at: t0)
    #expect(clock.elapsed(at: t0 - 1) == 0)
}

@Test(arguments: [
    (0.0, "0:00"), (0.99, "0:00"), (7.4, "0:07"), (59.99, "0:59"), (60, "1:00"),
    (754, "12:34"), (3599, "59:59"), (3600, "1:00:00"), (3723, "1:02:03"), (-3, "0:00"),
])
func labelsReadLikeAStopwatch(elapsed: TimeInterval, label: String) {
    #expect(RecordingClock.label(elapsed) == label)
}

@Test func theNextTickLandsOnTheNextWholeSecond() {
    var clock = RecordingClock()
    clock.start(at: t0)
    #expect(abs(clock.untilNextSecond(at: t0 + 2.25) - 0.75) < 1e-9)
    #expect(abs(clock.untilNextSecond(at: t0 + 3) - 1) < 1e-9)
}
