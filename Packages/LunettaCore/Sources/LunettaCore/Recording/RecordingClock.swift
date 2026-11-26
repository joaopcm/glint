import Foundation

/// Recorded time across pauses: the parts already finished plus the one running now.
public struct RecordingClock: Equatable, Sendable {
    public private(set) var banked: TimeInterval = 0
    public private(set) var runningSince: Date?

    public init() {}

    public var isRunning: Bool { runningSince != nil }

    public func elapsed(at now: Date) -> TimeInterval {
        banked + (runningSince.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }

    public mutating func start(at now: Date) {
        guard runningSince == nil else { return }
        runningSince = now
    }

    public mutating func pause(at now: Date) {
        banked = elapsed(at: now)
        runningSince = nil
    }

    /// "0:07", "12:34", "1:02:03": whole seconds, rounded down so the label never runs ahead of the file.
    public static func label(_ elapsed: TimeInterval) -> String {
        let total = Int(max(0, elapsed))
        let hours = total / 3600
        let minutes = total / 60 % 60
        let seconds = total % 60
        let paddedSeconds = seconds < 10 ? "0\(seconds)" : "\(seconds)"
        guard hours > 0 else { return "\(minutes):\(paddedSeconds)" }
        let paddedMinutes = minutes < 10 ? "0\(minutes)" : "\(minutes)"
        return "\(hours):\(paddedMinutes):\(paddedSeconds)"
    }

    /// How long until the label next changes, so a ticking display wakes once per second, on the second.
    public func untilNextSecond(at now: Date) -> TimeInterval {
        let elapsed = elapsed(at: now)
        return elapsed.rounded(.down) + 1 - elapsed
    }
}
