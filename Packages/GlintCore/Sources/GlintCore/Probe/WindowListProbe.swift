import Foundation

public enum WindowListProbe {
    public static let path = ProcessInfo.processInfo.environment["GLINT_WINDOW_LIST_PROBE"]
    public static let mode = ProcessInfo.processInfo.environment["GLINT_WINDOW_LIST_MODE"] ?? "overlayFirst"
    nonisolated(unsafe) private static var start: UInt64 = 0
    nonisolated(unsafe) private static var lines: [String] = []
    private static let lock = NSLock()

    public static func begin() {
        lock.lock(); defer { lock.unlock() }
        start = DispatchTime.now().uptimeNanoseconds
        lines.append("press")
    }

    public static func mark(_ phase: String) {
        guard path != nil else { return }
        lock.lock(); defer { lock.unlock() }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        lines.append("\(phase) \(String(format: "%.2f", ms)) \(Thread.isMainThread ? "main" : "bg")")
        if let path { try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8) }
    }
}
