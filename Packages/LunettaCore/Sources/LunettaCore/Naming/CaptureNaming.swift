import Foundation

public enum CaptureNaming {
    private static let posixCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    public static func baseName(for date: Date, timeZone: TimeZone) -> String {
        var calendar = posixCalendar
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = c.year!, month = c.month!, day = c.day!, hour = c.hour!, minute = c.minute!, second = c.second!
        guard (0...9999).contains(year) else {
            return String(format: "Lunetta %04d-%02d-%02d at %02d.%02d.%02d", year, month, day, hour, minute, second)
        }
        return String(unsafeUninitializedCapacity: 30) { out in
            // "Lunetta YYYY-MM-DD at HH.mm.ss" = 30 ASCII bytes
            out[0] = 0x4c; out[1] = 0x75; out[2] = 0x6e; out[3] = 0x65; out[4] = 0x74; out[5] = 0x74; out[6] = 0x61; out[7] = 0x20 // "Lunetta "
            SigV4.writeFourDigits(year, to: out, at: 8)
            out[12] = 0x2d
            SigV4.writeTwoDigits(month, to: out, at: 13)
            out[15] = 0x2d
            SigV4.writeTwoDigits(day, to: out, at: 16)
            out[18] = 0x20; out[19] = 0x61; out[20] = 0x74; out[21] = 0x20 // " at "
            SigV4.writeTwoDigits(hour, to: out, at: 22)
            out[24] = 0x2e
            SigV4.writeTwoDigits(minute, to: out, at: 25)
            out[27] = 0x2e
            SigV4.writeTwoDigits(second, to: out, at: 28)
            return 30
        }
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
