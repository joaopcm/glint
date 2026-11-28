import Darwin
import LunettaCore

public struct MemoryBudget: Sendable {
    public static let unlimited = MemoryBudget(limitMB: .max)

    // 2 x the 688.6 MB peak of a 6016x3384 HEVC export, see docs/perf/2026-11-28-render.md
    public static let render = MemoryBudget(limitMB: 1378)

    public let limitMB: Int

    public init(limitMB: Int) {
        self.limitMB = limitMB
    }

    public func check(output: PixelSize, footprintMB: () -> Int = MemoryBudget.currentFootprintMB) throws(RenderError) {
        let used = footprintMB()
        guard used <= limitMB else { throw .overMemoryBudget(limitMB: limitMB, usedMB: used, output: output) }
    }

    public static func currentFootprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        precondition(result == KERN_SUCCESS, "task_info(TASK_VM_INFO) failed with \(result), so the render memory budget can't be checked.")
        return Int(info.phys_footprint / 1_048_576)
    }
}
