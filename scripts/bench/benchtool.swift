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
// A 5 min trace of the owner's normal use (7,829 input events) had 99% of gaps between inputs under 0.4 s, so 3 s
// without input is a pause, not a gap between keystrokes.
let quietSecondsBeforePress = 3.0
// Same trace: after 3 s of quiet, input arrived within the next 0.5 s (one press) 63 times in 863 (7.3%). 10 presses in
// a row cut short is about 1 in 10^11, so reaching it means something sends input nonstop.
let retriesPerPress = 10

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

struct Hotkey {
    let key: CGKeyCode
    let modifiers: [Modifier]
    let chord: String

    var label: String { "`\(chord)` hotkey" }
}

struct App {
    let name: String
    let bundleID: String
    let url: URL
    let launchArguments: [String]
    let trigger: Hotkey

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

func fullDisplayWindows(of pid: pid_t, displayBounds: [CGRect]) -> Set<Int> {
    Set(onScreenWindows().compactMap { window in
        guard (window[kCGWindowOwnerPID as String] as? Int32) == pid,
              let rect = bounds(of: window), displayBounds.contains(rect)
        else { return nil }
        return window[kCGWindowNumber as String] as? Int
    })
}

let eventSource = CGEventSource(stateID: .hidSystemState)

func postKey(_ code: CGKeyCode, down: Bool, flags: CGEventFlags) {
    guard let event = CGEvent(keyboardEventSource: eventSource, virtualKey: code, keyDown: down) else {
        fail("could not create a key event for key code \(code)")
    }
    event.flags = flags
    event.post(tap: .cghidEventTap)
}

func fire(_ hotkey: Hotkey) -> UInt64 {
    var flags: CGEventFlags = []
    for modifier in hotkey.modifiers {
        flags.insert(modifier.flag)
        postKey(modifier.keyCode, down: true, flags: flags)
    }
    let start = uptimeNanoseconds()
    postKey(hotkey.key, down: true, flags: flags)
    postKey(hotkey.key, down: false, flags: flags)
    for modifier in hotkey.modifiers.reversed() {
        flags.remove(modifier.flag)
        postKey(modifier.keyCode, down: false, flags: flags)
    }
    return start
}

/// Keyboard and mouse input that isn't this tool's own posts: the owner's, or another app's acting for them.
final class OwnerInput: @unchecked Sendable {
    private let lock = NSLock()
    private var lastAt: UInt64 = 0
    private var total = 0

    var last: UInt64 { lock.withLock { lastAt } }
    var count: Int { lock.withLock { total } }

    func record() {
        lock.withLock {
            lastAt = uptimeNanoseconds()
            total += 1
        }
    }
}

let ownerInput = OwnerInput()
var inputTap: CFMachPort?

/// Our own posts carry this process's pid in `eventSourceUnixProcessID`, the keyboard and mouse carry 0. The idle clocks
/// can't tell them apart: `HIDIdleTime` and `CGEventSource.secondsSinceLastEventType` both reset on some of our posts.
func watchOwnerInput() {
    let types: [CGEventType] = [
        .keyDown, .keyUp, .flagsChanged, .mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
        .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel,
    ]
    let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
    inputTap = CGEvent.tapCreate(
        tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask,
        callback: { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let inputTap { CGEvent.tapEnable(tap: inputTap, enable: true) }
            } else if event.getIntegerValueField(.eventSourceUnixProcessID) != Int64(getpid()) {
                ownerInput.record()
            }
            return Unmanaged.passUnretained(event)
        },
        userInfo: nil
    )
    guard let inputTap else { fail("could not watch keyboard and mouse input. run `benchtool check` for the permission it needs") }
    Thread {
        CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, inputTap, 0), .commonModes)
        CGEvent.tapEnable(tap: inputTap, enable: true)
        CFRunLoopRun()
    }.start()
}

func waitForQuiet(before hotkey: Hotkey) {
    var announced = false
    while true {
        let quietFor = Double(uptimeNanoseconds() - ownerInput.last) / 1e9
        if quietFor >= quietSecondsBeforePress { return }
        if !announced {
            log("waiting for \(Int(quietSecondsBeforePress)) s without input to press \(hotkey.chord)…")
            announced = true
        }
        Thread.sleep(forTimeInterval: quietSecondsBeforePress - quietFor)
    }
}

enum Press {
    case shown(milliseconds: Double)
    case noOverlay
    case overlayStuck
}

func press(_ app: App, pid: pid_t, displayBounds: [CGRect]) -> Press {
    let timeout = UInt64(overlayTimeoutSeconds * 1e9)
    let escape: CGKeyCode = 53
    let before = fullDisplayWindows(of: pid, displayBounds: displayBounds)
    let start = fire(app.trigger)
    var overlay: Set<Int> = []
    var shownAt: UInt64?
    while uptimeNanoseconds() - start < timeout {
        overlay = fullDisplayWindows(of: pid, displayBounds: displayBounds).subtracting(before)
        if !overlay.isEmpty {
            shownAt = uptimeNanoseconds()
            break
        }
        usleep(pollIntervalMicroseconds)
    }
    guard let shownAt else { return .noOverlay }
    postKey(escape, down: true, flags: [])
    postKey(escape, down: false, flags: [])
    let dismissStart = uptimeNanoseconds()
    while !fullDisplayWindows(of: pid, displayBounds: displayBounds).isDisjoint(with: overlay) {
        if uptimeNanoseconds() - dismissStart > timeout { return .overlayStuck }
        usleep(pollIntervalMicroseconds)
    }
    return .shown(milliseconds: Double(shownAt - start) / 1e6)
}

func measureLatency(of app: App, pid: pid_t) -> (latencies: [Double], redone: Int) {
    let displayBounds = displays().map(CGDisplayBounds)
    var latencies: [Double] = []
    var redone = 0
    for number in 1...pressesPerApp {
        var interrupted = 0
        while true {
            waitForQuiet(before: app.trigger)
            let pressStart = uptimeNanoseconds()
            let outcome = press(app, pid: pid, displayBounds: displayBounds)
            if ownerInput.last >= pressStart {
                interrupted += 1
                redone += 1
                guard interrupted <= retriesPerPress else {
                    fail("""
                        keyboard or mouse input cut press \(number) of \(app.trigger.chord) short \(interrupted) times in a row, \
                        past retriesPerPress=\(retriesPerPress). something is sending input nonstop; stop it and rerun
                        """)
                }
                log("input during press \(number) of \(app.trigger.chord), redoing it")
                Thread.sleep(forTimeInterval: pressGapSeconds)
                continue
            }
            switch outcome {
            case .shown(let milliseconds):
                latencies.append(milliseconds)
            case .noOverlay:
                fail("""
                    \(app.name) showed no new full-display window within \(overlayTimeoutSeconds)s of \
                    \(app.trigger.label) on press \(number). check \(app.trigger.chord) is still its area capture shortcut in its settings
                    """)
            case .overlayStuck:
                fail("\(app.name)'s overlay still up \(overlayTimeoutSeconds)s after Esc on press \(number)")
            }
            break
        }
        Thread.sleep(forTimeInterval: pressGapSeconds)
    }
    return (latencies, redone)
}

struct IdleSample {
    let footprintMB: Double
    let cpuPercent: Double
    let wakeupsPerSecond: Double
    let inputEvents: Int
}

func measureIdle(of app: App) -> (samples: [IdleSample], pid: pid_t) {
    var samples: [IdleSample] = []
    var pid: pid_t = 0
    for launch in 1...launchesPerApp {
        app.quit()
        pid = app.launch()
        log("\(app.name): launch \(launch)/\(launchesPerApp), measuring idle for \(Int(idleSettleSeconds + idleSampleSeconds))s")
        let inputBefore = ownerInput.count
        Thread.sleep(forTimeInterval: idleSettleSeconds)
        let settled = usage(of: pid, app: app.name)
        Thread.sleep(forTimeInterval: idleSampleSeconds)
        let sampled = usage(of: pid, app: app.name)
        samples.append(IdleSample(
            footprintMB: Double(settled.footprintBytes) / 1_048_576,
            cpuPercent: Double(sampled.cpuNanoseconds - settled.cpuNanoseconds) / (idleSampleSeconds * 1e9) * 100,
            wakeupsPerSecond: Double(sampled.wakeups - settled.wakeups) / idleSampleSeconds,
            inputEvents: ownerInput.count - inputBefore
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

/// Only booleans: the owner's other settings include bucket names and URLs that don't belong in a public report.
func savedToggles(of bundleID: String, except pinned: [String]) -> String {
    let keys = CFPreferencesCopyKeyList(bundleID as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] ?? []
    let toggles = keys.sorted().compactMap { key -> String? in
        guard !pinned.contains(key), !key.hasPrefix("NS"), !key.hasPrefix("com_apple_"),
              let value = CFPreferencesCopyAppValue(key as CFString, bundleID as CFString),
              CFGetTypeID(value) == CFBooleanGetTypeID()
        else { return nil }
        return "`\(key)` \(CFBooleanGetValue((value as! CFBoolean)) ? "on" : "off")"
    }
    return toggles.isEmpty ? "none" : toggles.joined(separator: ", ")
}

func format(_ value: Double, _ digits: Int = 1) -> String { String(format: "%.\(digits)f", value) }

func ratio(_ theirs: Double, _ ours: Double) -> String {
    guard ours > 0 else { return "n/a" }
    return "\(format(theirs / ours))×"
}

func argument(_ name: String) -> String {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
        fail("missing \(name). usage: benchtool check | benchtool run --lunetta <app> --built-from <git ref> --cleanshot <app> --report <md> --readme <md>")
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
    guard CGPreflightListenEventAccess() else {
        fail("""
            this terminal can't watch keyboard and mouse input, which the run needs to wait for you to stop typing before \
            each press. grant it Input Monitoring in System Settings > Privacy & Security > Input Monitoring (the app that \
            runs the shell, e.g. Terminal or T3 Code), then rerun
            """)
    }
    exit(0)
}

guard CommandLine.arguments.dropFirst().first == "run" else { _ = argument("--lunetta"); exit(1) }

let lunettaURL = URL(fileURLWithPath: argument("--lunetta"))
let builtFrom = argument("--built-from")
let cleanShotURL = URL(fileURLWithPath: argument("--cleanshot"))
let reportURL = URL(fileURLWithPath: argument("--report"))
let readmeURL = URL(fileURLWithPath: argument("--readme"))

// Pinned through the argument domain so a shortcut or freeze screen changed in Settings can't change what's measured.
// Freeze screen is off for both, Lunetta's default. Plist `<false/>`, not NO: the argument domain passes NO as a
// string, and CleanShot X reads strings as off (YES included), so only a plist bool really pins it. Compress copied
// media is pinned to its default off too: on, it checks the clipboard while the owner uses the Mac during the run.
let lunettaPinned = ["freezeScreenWhileSelecting", "compressCopiedMedia"]
let lunetta = App(
    name: "Lunetta",
    bundleID: "com.joaopcm.lunetta",
    url: lunettaURL,
    launchArguments: [
        "-KeyboardShortcuts_captureArea", #""{\"carbonKeyCode\":19,\"carbonModifiers\":768}""#,
        "-freezeScreenWhileSelecting", "<false/>",
        "-compressCopiedMedia", "<false/>",
    ],
    trigger: Hotkey(key: 19, modifiers: [.shift, .command], chord: "⇧⌘2")
)
// CleanShot X keeps its shortcuts in its group container, out of reach of the argument domain, so this relies on
// Capture Area still being its default ⇧⌘4.
guard let cleanShotBundleID = Bundle(url: cleanShotURL)?.bundleIdentifier else { fail("\(cleanShotURL.path) is not an app bundle") }
let cleanShot = App(
    name: "CleanShot X",
    bundleID: cleanShotBundleID,
    url: cleanShotURL,
    launchArguments: ["-freezeScreen", "<false/>"],
    trigger: Hotkey(key: 21, modifiers: [.shift, .command], chord: "⇧⌘4")
)

struct Result {
    let app: App
    let idle: [IdleSample]
    let latencies: [Double]
    let redone: Int
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
let lunettaToggles = savedToggles(of: lunetta.bundleID, except: lunettaPinned)
watchOwnerInput()

var results: [Result] = []
for app in [lunetta, cleanShot] {
    for other in [lunetta, cleanShot] where other.bundleID != app.bundleID { other.quit() }
    let (idle, pid) = measureIdle(of: app)
    log("\(app.name): \(pressesPerApp) presses of \(app.trigger.label), \(Int(pressGapSeconds))s apart")
    let (latencies, redone) = measureLatency(of: app, pid: pid)
    app.quit()
    results.append(Result(app: app, idle: idle, latencies: latencies, redone: redone, sizeMB: bundleSizeMB(app.url)))
}
let ours = results[0]
let theirs = results[1]
let inputDuringRun = ownerInput.count
let desktopUse = inputDuringRun == 0
    ? "nobody used the Mac during the run: 0 keyboard or mouse events"
    : "the owner used the Mac during the run: \(inputDuringRun) keyboard and mouse events (counts per launch below)"

let commit = lunetta.bundle.infoDictionary?["LunettaCommit"] as? String ?? "unknown"
let osVersion = {
    let version = ProcessInfo.processInfo.operatingSystemVersion
    return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
}()

func samples(_ values: [Double], digits: Int = 1, suffix: String) -> String {
    values.map { format($0, digits) + suffix }.joined(separator: ", ")
}

let report = """
# Lunetta vs CleanShot X, \(date)

| | Lunetta | CleanShot X | CleanShot X / Lunetta |
| --- | --- | --- | --- |
| idle memory | \(format(ours.footprint)) MB | \(format(theirs.footprint)) MB | \(ratio(theirs.footprint, ours.footprint)) |
| idle CPU | \(format(ours.cpu, 3))% | \(format(theirs.cpu, 3))% | \(ratio(theirs.cpu, ours.cpu)) |
| idle wakeups | \(format(ours.wakeups, 2))/s | \(format(theirs.wakeups, 2))/s | \(ratio(theirs.wakeups, ours.wakeups)) |
| area overlay, trigger to screen | \(format(ours.latency)) ms | \(format(theirs.latency)) ms | \(ratio(theirs.latency, ours.latency)) |
| app size on disk | \(format(ours.sizeMB)) MB | \(format(theirs.sizeMB)) MB | \(ratio(theirs.sizeMB, ours.sizeMB)) |

Idle numbers are medians of \(launchesPerApp) launches, latency the median of \(pressesPerApp) presses. Lower is better everywhere.

## setup

- \(sysctlString("hw.model")) (\(sysctlString("machdep.cpu.brand_string"))), macOS \(osVersion)
- displays: \(displayDescription()). \(windowCount) visible windows
- normal desktop load, not a clean boot. \(desktopUse)
- Lunetta: Release build of `\(builtFrom)` at \(commit), `\(lunettaURL.path)`, the owner's settings with area hotkey \
pinned to `⇧⌘2`, freeze screen and compress copied media pinned to their default off. other toggles the owner has saved: \
\(lunettaToggles)
- CleanShot X: \(cleanShot.version) (`\(cleanShot.bundleID)`), the owner's settings except freeze screen pinned off, area hotkey \
its default `⇧⌘4`

## idle

each app quit and relaunched in the background, the other one quit. footprint read \(Int(idleSettleSeconds)) s after launch, \
CPU time and wakeups counted over the next \(Int(idleSampleSeconds)) s, all from `proc_pid_rusage`. footprint is the same \
number `footprint <pid>` reports. the owner may use the Mac meanwhile; the last column counts their keyboard and mouse \
events in those \(Int(idleSettleSeconds + idleSampleSeconds)) s, so a busy launch can be told from a quiet one.

| app | footprint | CPU | wakeups | input events |
| --- | --- | --- | --- | --- |
| Lunetta | \(samples(ours.idle.map(\.footprintMB), suffix: " MB")) | \(ours.idle.map { format($0.cpuPercent, 3) + "%" }.joined(separator: ", ")) | \(samples(ours.idle.map(\.wakeupsPerSecond), digits: 2, suffix: "/s")) | \(ours.idle.map { String($0.inputEvents) }.joined(separator: ", ")) |
| CleanShot X | \(samples(theirs.idle.map(\.footprintMB), suffix: " MB")) | \(theirs.idle.map { format($0.cpuPercent, 3) + "%" }.joined(separator: ", ")) | \(samples(theirs.idle.map(\.wakeupsPerSecond), digits: 2, suffix: "/s")) | \(theirs.idle.map { String($0.inputEvents) }.joined(separator: ", ")) |

## trigger to overlay on screen

\(pressesPerApp) presses per app, \(Int(pressGapSeconds)) s apart, Esc after each. both apps get the same input: `CGEvent` key \
events from a `.hidSystemState` source posted at the HID event tap, modifiers as separate presses, through each app's own \
area hotkey. right before it, the app's on-screen windows are snapshotted. t0 is taken right before the main key-down, then \
`CGWindowListCopyWindowInfo` is polled every \(pollIntervalMicroseconds) µs. t1 is the first poll with an on-screen window from \
the app that covers a whole display, on any layer, and wasn't in the snapshot. after Esc, the same windows have to leave the \
screen before the next press.

each press waits for \(Int(quietSecondsBeforePress)) s without keyboard or mouse input from the owner, and a press their \
input lands in, from trigger to dismissal, is thrown away and done again. their input is told from the tool's own posts by \
the posting pid, through a listen-only event tap.

| app | trigger | median | min | max | redone |
| --- | --- | --- | --- | --- | --- |
| Lunetta area | \(lunetta.trigger.label) | \(format(ours.latency)) ms | \(format(ours.latencies.min()!)) ms | \(format(ours.latencies.max()!)) ms | \(ours.redone) |
| CleanShot X area | \(cleanShot.trigger.label) | \(format(theirs.latency)) ms | \(format(theirs.latencies.min()!)) ms | \(format(theirs.latencies.max()!)) ms | \(theirs.redone) |

## what's off about this comparison

- the number is trigger to window-server order-in, not to photons. display scan-out is left out for both apps
- the hotkeys are synthetic events, not a physical keyboard. both apps take the same path, so the comparison holds, but \
the absolute numbers leave out the keyboard and HID driver
- both run with freeze screen off. that way CleanShot X shows nothing you can see except the cursor: its full-display \
window sits at layer -2147483600, behind other apps' windows. so for CleanShot X, t1 is when it enters area capture, not \
when something is drawn. with freeze on, that window orders in in the same poll as its visible overlay (3 of 3 presses \
checked), so it's the same moment either way
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
idle CPU \(format(ours.cpu, 3))% vs \(format(theirs.cpu, 3))%, area overlay \(format(ours.latency)) ms median from hotkey vs \
\(format(theirs.latency)) ms, app size \(format(ours.sizeMB, 0)) MB vs \(format(theirs.sizeMB, 0)) MB. Both apps got the same \
synthetic hotkey with freeze screen off, and latency is to the window server ordering in each app's full-display capture \
window, not to photons on screen. Details in [\(reportLink)](\(reportLink)).
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
