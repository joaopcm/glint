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
            return String(format: "Glint %04d-%02d-%02d at %02d.%02d.%02d", year, month, day, hour, minute, second)
        }
        return String(unsafeUninitializedCapacity: 28) { out in
            // "Glint YYYY-MM-DD at HH.mm.ss" = 28 ASCII bytes
            out[0] = 0x47; out[1] = 0x6c; out[2] = 0x69; out[3] = 0x6e; out[4] = 0x74; out[5] = 0x20 // "Glint "
            SigV4.writeFourDigits(year, to: out, at: 6)
            out[10] = 0x2d
            SigV4.writeTwoDigits(month, to: out, at: 11)
            out[13] = 0x2d
            SigV4.writeTwoDigits(day, to: out, at: 14)
            out[16] = 0x20; out[17] = 0x61; out[18] = 0x74; out[19] = 0x20 // " at "
            SigV4.writeTwoDigits(hour, to: out, at: 20)
            out[22] = 0x2e
            SigV4.writeTwoDigits(minute, to: out, at: 23)
            out[25] = 0x2e
            SigV4.writeTwoDigits(second, to: out, at: 26)
            return 28
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
