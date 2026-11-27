import AppKit
import CoreGraphics
import Darwin

// Method and numbers from https://github.com/joaopcm/glint/issues/3#issuecomment-7145993290
let idleSettleSeconds = 60.0
let idleSampleSeconds = 60.0
let launchesPerApp = 3
let pressesPerApp = 10
let pressGapSeconds = 2.0
let pollIntervalMicroseconds: useconds_t = 250
// Slowest overlay in #3 was 150.7 ms; 3 s only trips when the trigger never landed.
let overlayTimeoutSeconds = 3.0
// install-local.sh measured quit at 0.08–0.16 s; 10 s only trips on a hung app.
let quitTimeoutSeconds = 10.0
// Measured open to process at 0.18–0.21 s over 3 launches each of Lunetta and CleanShot X; 10 s only trips when the app never starts.
let launchTimeoutSeconds = 10.0

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}

func uptimeNanoseconds() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

@discardableResult
func run(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { fail("could not run \(path): \(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

enum Modifier: CaseIterable {
    case control, option, shift, command

    var keyCode: CGKeyCode {
        switch self {
        case .control: 59
        case .option: 58
        case .shift: 56
        case .command: 55
        }
    }

    var flag: CGEventFlags {
        switch self {
        case .control: .maskControl
        case .option: .maskAlternate
        case .shift: .maskShift
        case .command: .maskCommand
        }
    }
}

enum Trigger {
    case hotkey(key: CGKeyCode, modifiers: [Modifier], label: String)
    case url(URL)

    var label: String {
        switch self {
        case .hotkey(_, _, let label): "`\(label)` hotkey"
        case .url(let url): "`\(url.absoluteString)`"
        }
    }
}

struct App {
    let name: String
    let bundleID: String
    let url: URL
    let launchArguments: [String]
    let trigger: Trigger

    var bundle: Bundle {
        guard let bundle = Bundle(url: url) else { fail("\(url.path) is not an app bundle") }
        return bundle
    }

    var processName: String {
        guard let executable = bundle.executableURL?.lastPathComponent else { fail("\(url.path) has no executable") }
        return executable
    }

    var version: String {
        bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    func pid() -> pid_t? {
        let result = run("/usr/bin/pgrep", ["-x", processName])
        return result.output.split(separator: "\n").first.flatMap { pid_t($0) }
    }

    func quit() {
        guard pid() != nil else { return }
        run("/usr/bin/osascript", ["-e", "quit app id \"\(bundleID)\""])
        let deadline = Date().addingTimeInterval(quitTimeoutSeconds)
        while pid() != nil {
            if Date() > deadline { fail("\(name) still running \(Int(quitTimeoutSeconds))s after quit; quit it and rerun") }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    func launch() -> pid_t {
        let status = run("/usr/bin/open", ["-g", "-a", url.path, "--args"] + launchArguments).status
        guard status == 0 else { fail("open \(url.path) exited \(status)") }
        let deadline = Date().addingTimeInterval(launchTimeoutSeconds)
        while true {
            if let pid = pid() { return pid }
            if Date() > deadline { fail("\(name) has no \"\(processName)\" process \(Int(launchTimeoutSeconds))s after launch") }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
}

struct Usage {
    let footprintBytes: UInt64
    let cpuNanoseconds: UInt64
    let wakeups: UInt64
}

let timebase: mach_timebase_info_data_t = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return info
}()

func usage(of pid: pid_t, app: String) -> Usage {
    var info = rusage_info_v4()
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
        }
    }
    guard status == 0 else { fail("proc_pid_rusage(\(pid)) for \(app) failed: \(String(cString: strerror(errno)))") }
    // ri_user_time and ri_system_time are mach ticks, not nanoseconds, on Apple silicon.
    let ticks = info.ri_user_time + info.ri_system_time
    return Usage(
        footprintBytes: info.ri_phys_footprint,
        cpuNanoseconds: ticks * UInt64(timebase.numer) / UInt64(timebase.denom),
        wakeups: info.ri_pkg_idle_wkups + info.ri_interrupt_wkups
    )
}

func displays() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    return ids
}

func onScreenWindows() -> [[String: Any]] {
    CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
}

func bounds(of window: [String: Any]) -> CGRect? {
    guard let dictionary = window[kCGWindowBounds as String] as? [String: Any] else { return nil }
    return CGRect(dictionaryRepresentation: dictionary as CFDictionary)
}

func fullDisplayOverlays(of pid: pid_t, displayBounds: [CGRect]) -> Int {
    onScreenWindows().filter { window in
        guard (window[kCGWindowOwnerPID as String] as? Int32) == pid,
              let layer = window[kCGWindowLayer as String] as? Int, layer > 0,
              let rect = bounds(of: window)
        else { return false }
        return displayBounds.contains(rect)
    }.count
}

let eventSource = CGEventSource(stateID: .hidSystemState)

func postKey(_ code: CGKeyCode, down: Bool, flags: CGEventFlags) {
    guard let event = CGEvent(keyboardEventSource: eventSource, virtualKey: code, keyDown: down) else {
        fail("could not create a key event for key code \(code)")
    }
    event.flags = flags
    event.post(tap: .cghidEventTap)
}

func fire(_ trigger: Trigger) -> UInt64 {
    switch trigger {
    case .hotkey(let key, let modifiers, _):
        var flags: CGEventFlags = []
        for modifier in modifiers {
            flags.insert(modifier.flag)
            postKey(modifier.keyCode, down: true, flags: flags)
        }
        let start = uptimeNanoseconds()
        postKey(key, down: true, flags: flags)
        postKey(key, down: false, flags: flags)
        for modifier in modifiers.reversed() {
            flags.remove(modifier.flag)
            postKey(modifier.keyCode, down: false, flags: flags)
        }
        return start
    case .url(let url):
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        let start = uptimeNanoseconds()
        NSWorkspace.shared.open(url, configuration: configuration)
        return start
    }
}

func measureLatency(of app: App, pid: pid_t) -> [Double] {
    let displayBounds = displays().map(CGDisplayBounds)
    let timeout = UInt64(overlayTimeoutSeconds * 1e9)
    let escape: CGKeyCode = 53
    var latencies: [Double] = []
    for press in 1...pressesPerApp {
        guard fullDisplayOverlays(of: pid, displayBounds: displayBounds) == 0 else {
            fail("\(app.name) already shows a full-display overlay before press \(press); dismiss it and rerun")
        }
        let start = fire(app.trigger)
        var shownAt: UInt64?
        while uptimeNanoseconds() - start < timeout {
            if fullDisplayOverlays(of: pid, displayBounds: displayBounds) > 0 {
                shownAt = uptimeNanoseconds()
                break
            }
            usleep(pollIntervalMicroseconds)
        }
        guard let shownAt else {
            fail("""
                \(app.name) showed no full-display window above layer 0 within \(overlayTimeoutSeconds)s of \
                \(app.trigger.label) on press \(press). check the trigger still opens its area capture
                """)
        }
        latencies.append(Double(shownAt - start) / 1e6)
        postKey(escape, down: true, flags: [])
        postKey(escape, down: false, flags: [])
        let dismissStart = uptimeNanoseconds()
        while fullDisplayOverlays(of: pid, displayBounds: displayBounds) > 0 {
            if uptimeNanoseconds() - dismissStart > timeout {
                fail("\(app.name)'s overlay still up \(overlayTimeoutSeconds)s after Esc on press \(press)")
            }
            usleep(pollIntervalMicroseconds)
        }
        Thread.sleep(forTimeInterval: pressGapSeconds)
    }
    return latencies
}

struct IdleSample {
    let footprintMB: Double
    let cpuPercent: Double
    let wakeupsPerSecond: Double
}

func measureIdle(of app: App) -> (samples: [IdleSample], pid: pid_t) {
    var samples: [IdleSample] = []
    var pid: pid_t = 0
    for launch in 1...launchesPerApp {
        app.quit()
        pid = app.launch()
        log("\(app.name): launch \(launch)/\(launchesPerApp), hands off for \(Int(idleSettleSeconds + idleSampleSeconds))s")
        Thread.sleep(forTimeInterval: idleSettleSeconds)
        let settled = usage(of: pid, app: app.name)
        Thread.sleep(forTimeInterval: idleSampleSeconds)
        let sampled = usage(of: pid, app: app.name)
        samples.append(IdleSample(
            footprintMB: Double(settled.footprintBytes) / 1_048_576,
            cpuPercent: Double(sampled.cpuNanoseconds - settled.cpuNanoseconds) / (idleSampleSeconds * 1e9) * 100,
            wakeupsPerSecond: Double(sampled.wakeups - settled.wakeups) / idleSampleSeconds
        ))
    }
    return (samples, pid)
}

func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    let middle = sorted.count / 2
    return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
}

func bundleSizeMB(_ url: URL) -> Double {
    guard let enumerator = FileManager.default.enumerator(
        at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey], options: []
    ) else { fail("could not read \(url.path)") }
    var bytes = 0
    for case let file as URL in enumerator {
        bytes += (try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0
    }
    return Double(bytes) / 1_048_576
}

func sysctlString(_ name: String) -> String {
    var size = 0
    sysctlbyname(name, nil, &size, nil, 0)
    var buffer = [CChar](repeating: 0, count: size)
    sysctlbyname(name, &buffer, &size, nil, 0)
    return String(cString: buffer)
}

func displayDescription() -> String {
    displays().map { id in
        guard let mode = CGDisplayCopyDisplayMode(id) else { return "display \(id)" }
        return "\(mode.width)x\(mode.height) @ \(Int(mode.refreshRate.rounded())) Hz"
    }.joined(separator: ", ")
}

func visibleWindowCount() -> Int {
    onScreenWindows().filter {
        ($0[kCGWindowLayer as String] as? Int) == 0 && (($0[kCGWindowAlpha as String] as? Double) ?? 0) > 0
    }.count
}

func format(_ value: Double, _ digits: Int = 1) -> String { String(format: "%.\(digits)f", value) }

func ratio(_ theirs: Double, _ ours: Double) -> String {
    guard ours > 0 else { return "n/a" }
    return "\(format(theirs / ours))×"
}

func argument(_ name: String) -> String {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
        fail("missing \(name). usage: benchtool check | benchtool run --lunetta <app> --cleanshot <app> --report <md> --readme <md>")
    }
    return arguments[index + 1]
}

if CommandLine.arguments.dropFirst().first == "check" {
    guard AXIsProcessTrusted() else {
        fail("""
            this terminal can't post key events. grant it Accessibility in System Settings > Privacy & Security > \
            Accessibility (the app that runs the shell, e.g. Terminal or T3 Code), then rerun
            """)
    }
    exit(0)
}

guard CommandLine.arguments.dropFirst().first == "run" else { _ = argument("--lunetta"); exit(1) }

let lunettaURL = URL(fileURLWithPath: argument("--lunetta"))
let cleanShotURL = URL(fileURLWithPath: argument("--cleanshot"))
let reportURL = URL(fileURLWithPath: argument("--report"))
let readmeURL = URL(fileURLWithPath: argument("--readme"))

// Pinned through the argument domain so a shortcut rebound in Settings can't make every press miss, and so a
// freeze screen turned on in Settings can't slow the overlay down: on, it measured 103–218 ms against 27–42 ms off.
let lunetta = App(
    name: "Lunetta",
    bundleID: "com.joaopcm.lunetta",
    url: lunettaURL,
    launchArguments: [
        "-KeyboardShortcuts_captureArea", #""{\"carbonKeyCode\":19,\"carbonModifiers\":768}""#,
        "-freezeScreenWhileSelecting", "NO",
    ],
    trigger: .hotkey(key: 19, modifiers: [.shift, .command], label: "⇧⌘2")
)
// CleanShot X ignores synthetic key events (#3), so its URL API is the only trigger that works.
guard let cleanShotBundleID = Bundle(url: cleanShotURL)?.bundleIdentifier else { fail("\(cleanShotURL.path) is not an app bundle") }
let cleanShot = App(
    name: "CleanShot X",
    bundleID: cleanShotBundleID,
    url: cleanShotURL,
    launchArguments: [],
    trigger: .url(URL(string: "cleanshot://capture-area")!)
)

struct Result {
    let app: App
    let idle: [IdleSample]
    let latencies: [Double]
    let sizeMB: Double

    var footprint: Double { median(idle.map(\.footprintMB)) }
    var cpu: Double { median(idle.map(\.cpuPercent)) }
    var wakeups: Double { median(idle.map(\.wakeupsPerSecond)) }
    var latency: Double { median(latencies) }
}

let date = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: Date())
}()
let windowCount = visibleWindowCount()

var results: [Result] = []
for app in [lunetta, cleanShot] {
    for other in [lunetta, cleanShot] where other.bundleID != app.bundleID { other.quit() }
    let (idle, pid) = measureIdle(of: app)
    log("\(app.name): \(pressesPerApp) presses of \(app.trigger.label), \(Int(pressGapSeconds))s apart")
    let latencies = measureLatency(of: app, pid: pid)
    app.quit()
    results.append(Result(app: app, idle: idle, latencies: latencies, sizeMB: bundleSizeMB(app.url)))
}
let ours = results[0]
let theirs = results[1]

let commit = lunetta.bundle.infoDictionary?["LunettaCommit"] as? String ?? "unknown"
let osVersion = {
    let version = ProcessInfo.processInfo.operatingSystemVersion
    return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
}()

func samples(_ values: [Double], unit: String) -> String {
    values.map { "\(format($0)) \(unit)" }.joined(separator: ", ")
}

let report = """
# Lunetta vs CleanShot X, \(date)

| | Lunetta | CleanShot X | CleanShot X / Lunetta |
| --- | --- | --- | --- |
| idle memory | \(format(ours.footprint)) MB | \(format(theirs.footprint)) MB | \(ratio(theirs.footprint, ours.footprint)) |
| idle CPU | \(format(ours.cpu, 2))% | \(format(theirs.cpu, 2))% | \(ratio(theirs.cpu, ours.cpu)) |
| idle wakeups | \(format(ours.wakeups))/s | \(format(theirs.wakeups))/s | \(ratio(theirs.wakeups, ours.wakeups)) |
| area overlay, trigger to screen | \(format(ours.latency)) ms | \(format(theirs.latency)) ms | \(ratio(theirs.latency, ours.latency)) |
| app size on disk | \(format(ours.sizeMB)) MB | \(format(theirs.sizeMB)) MB | \(ratio(theirs.sizeMB, ours.sizeMB)) |

Idle numbers are medians of \(launchesPerApp) launches, latency the median of \(pressesPerApp) presses. Lower is better everywhere.

## setup

- \(sysctlString("hw.model")) (\(sysctlString("machdep.cpu.brand_string"))), macOS \(osVersion)
- displays: \(displayDescription()). \(windowCount) visible windows
- normal desktop load, not a clean boot
- Lunetta: Release build of `main` at \(commit), `\(lunettaURL.path)`, default settings, area hotkey pinned to `⇧⌘2` and freeze screen pinned off
- CleanShot X: \(cleanShot.version) (`\(cleanShot.bundleID)`), the owner's settings

## idle

each app quit and relaunched in the background, the other one quit. footprint read \(Int(idleSettleSeconds)) s after launch, \
CPU time and wakeups counted over the next \(Int(idleSampleSeconds)) s, all from `proc_pid_rusage`. footprint is the same \
number `footprint <pid>` reports.

| app | footprint | CPU | wakeups |
| --- | --- | --- | --- |
| Lunetta | \(samples(ours.idle.map(\.footprintMB), unit: "MB")) | \(ours.idle.map { format($0.cpuPercent, 2) + "%" }.joined(separator: ", ")) | \(samples(ours.idle.map(\.wakeupsPerSecond), unit: "/s")) |
| CleanShot X | \(samples(theirs.idle.map(\.footprintMB), unit: "MB")) | \(theirs.idle.map { format($0.cpuPercent, 2) + "%" }.joined(separator: ", ")) | \(samples(theirs.idle.map(\.wakeupsPerSecond), unit: "/s")) |

## trigger to overlay on screen

\(pressesPerApp) presses per app, \(Int(pressGapSeconds)) s apart, Esc after each. t0 is taken right before the trigger is posted, \
then `CGWindowListCopyWindowInfo` is polled every \(pollIntervalMicroseconds) µs. t1 is the first poll with an on-screen window \
from the app above layer 0 that covers a whole display.

| app | trigger | median | min | max |
| --- | --- | --- | --- | --- |
| Lunetta area | \(lunetta.trigger.label) | \(format(ours.latency)) ms | \(format(ours.latencies.min()!)) ms | \(format(ours.latencies.max()!)) ms |
| CleanShot X area | \(cleanShot.trigger.label) | \(format(theirs.latency)) ms | \(format(theirs.latencies.min()!)) ms | \(format(theirs.latencies.max()!)) ms |

## what's off about this comparison

- the number is trigger to window-server order-in, not to photons. display scan-out is left out for both apps
- CleanShot X ignores synthetic key events, so it's triggered through `cleanshot://capture-area` with `NSWorkspace.open`, \
no activation. that adds LaunchServices URL dispatch to CleanShot's number only, which favors Lunetta
- CleanShot X runs with its owner's settings (freeze screen and all), Lunetta with defaults (freeze screen off)
- app size counts what each bundle ships. CleanShot X's Setapp build also needs the Setapp agent, which isn't counted

generated by `scripts/bench.sh`. method from [#3](https://github.com/joaopcm/glint/issues/3#issuecomment-7145993290).

"""

do {
    try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try report.write(to: reportURL, atomically: true, encoding: .utf8)
} catch { fail("could not write \(reportURL.path): \(error)") }

let chip = sysctlString("machdep.cpu.brand_string").replacingOccurrences(of: "Apple ", with: "")
let reportLink = reportURL.path.replacingOccurrences(of: readmeURL.deletingLastPathComponent().path + "/", with: "")
let summary = """
Measured \(date) on an \(chip), macOS \(osVersion), \
against CleanShot X \(cleanShot.version): idle memory \(format(ours.footprint, 0)) MB vs \(format(theirs.footprint, 0)) MB, \
idle CPU \(format(ours.cpu, 2))% vs \(format(theirs.cpu, 2))%, area overlay \(format(ours.latency)) ms median from trigger vs \
\(format(theirs.latency)) ms, app size \(format(ours.sizeMB, 0)) MB vs \(format(theirs.sizeMB, 0)) MB. Latency is to the window \
server showing the overlay, not to photons on screen, and CleanShot X was triggered through its URL API, which adds time to its \
number only. Details in [\(reportLink)](\(reportLink)).
"""

guard let readme = try? String(contentsOf: readmeURL, encoding: .utf8) else { fail("could not read \(readmeURL.path)") }
var lines = readme.components(separatedBy: "\n")
guard let heading = lines.firstIndex(of: "## Performance") else { fail("\(readmeURL.path) has no \"## Performance\" section") }
let nextHeading = lines[(heading + 1)...].firstIndex { $0.hasPrefix("## ") } ?? lines.count
lines.replaceSubrange((heading + 1)..<nextHeading, with: ["", summary, ""])
do {
    try lines.joined(separator: "\n").write(to: readmeURL, atomically: true, encoding: .utf8)
} catch { fail("could not write \(readmeURL.path): \(error)") }

print(report)
