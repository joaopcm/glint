import LunettaCore

public struct ProjectTimeline: Sendable {
    private let screenStarts: [Double]
    private let partDurations: [Double]
    public let duration: Double

    public init(project: RecordingProject, partDurations: [Double]) {
        precondition(
            !partDurations.isEmpty && partDurations.count == project.parts.count,
            "A timeline needs one duration per part: the project has \(project.parts.count) parts, got \(partDurations.count) durations."
        )
        screenStarts = project.parts.map(\.screenStartHostTime)
        self.partDurations = partDurations
        duration = partDurations.reduce(0, +)
    }

    public func locate(_ t: Double) -> (part: Int, partTime: Double, hostTime: Double) {
        var partStart = 0.0
        for (part, length) in partDurations.enumerated() {
            if t < partStart + length || part == partDurations.count - 1 {
                let partTime = max(0, t - partStart)
                return (part, partTime, screenStarts[part] + partTime)
            }
            partStart += length
        }
        preconditionFailure("init guarantees at least one part")
    }
}
