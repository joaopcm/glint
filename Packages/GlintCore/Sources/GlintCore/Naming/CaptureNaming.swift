import Foundation

public enum CaptureNaming {
    public static func baseName(for date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Glint \(formatter.string(from: date))"
    }

    public static func uniqueFileURL(in folder: URL, baseName: String, ext: String, exists: (URL) -> Bool) -> URL {
        var candidate = folder.appending(path: "\(baseName).\(ext)")
        var counter = 2
        while exists(candidate) {
            candidate = folder.appending(path: "\(baseName) (\(counter)).\(ext)")
            counter += 1
        }
        return candidate
    }
}
