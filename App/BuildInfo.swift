import Foundation

enum BuildInfo {
    static func label(from info: [String: Any]?) -> String {
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let commit = info?["LunettaCommit"] as? String ?? "?"
        return "Lunetta \(version) (\(build)) \(commit)"
    }
}
