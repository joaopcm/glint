import AppKit
import XCTest

class WindowListProbeBase: GlintUITestCase {
    var mode: String { "overlayFirst" }
    lazy var probeFile = FileManager.default.temporaryDirectory.appending(path: "glint-probe-\(UUID().uuidString).txt")
    override var extraLaunchEnvironment: [String: String] {
        ["GLINT_WINDOW_LIST_PROBE": probeFile.path, "GLINT_WINDOW_LIST_MODE": mode]
    }

    @MainActor func measure() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "glint-probe-windows-\(UUID().uuidString)")
        for index in 0..<24 {
            let folder = root.appending(path: "w\(index)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(4))
        addTeardownBlock {
            let script = NSAppleScript(source: "tell application \"Finder\" to close every window")
            script?.executeAndReturnError(nil)
        }
        for _ in 0..<12 {
            press(.window)
            waitForOverlay(after: .window)
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            pressEscape()
            assertOverlayClosed(after: .window)
        }
        let text = (try? String(contentsOf: probeFile, encoding: .utf8)) ?? ""
        var presses: [[String: Double]] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ")
            if parts.first == "press" { presses.append([:]); continue }
            guard parts.count >= 2, let ms = Double(parts[1]), !presses.isEmpty else { continue }
            presses[presses.count - 1][String(parts[0])] = ms
        }
        print("PROBE \(mode) raw:\n\(text)")
        for phase in ["overlayUp", "mainFreeAfterOverlay", "scStart", "scEnd", "actorReturn", "taskReturn", "listOnMain"] {
            let values = presses.compactMap { $0[phase] }.sorted()
            guard !values.isEmpty else { continue }
            print(String(format: "PROBE %@ %@ median %.2f min %.2f max %.2f n %d", mode, phase, values[values.count / 2], values[0], values[values.count - 1], values.count))
        }
        let hop = presses.compactMap { p in p["listOnMain"].flatMap { main in p["actorReturn"].map { main - $0 } } }.sorted()
        if !hop.isEmpty { print(String(format: "PROBE %@ hop(actorReturn->listOnMain) median %.2f min %.2f max %.2f", mode, hop[hop.count / 2], hop[0], hop[hop.count - 1])) }
        let sc = presses.compactMap { p in p["scEnd"].flatMap { end in p["scStart"].map { end - $0 } } }.sorted()
        if !sc.isEmpty { print(String(format: "PROBE %@ sc(scStart->scEnd) median %.2f min %.2f max %.2f", mode, sc[sc.count / 2], sc[0], sc[sc.count - 1])) }
    }
}

final class WindowListProbeOverlayFirstUITests: WindowListProbeBase {
    @MainActor func testMeasure() throws { try measure() }
}

final class WindowListProbeListFirstUITests: WindowListProbeBase {
    override var mode: String { "listFirst" }
    @MainActor func testMeasure() throws { try measure() }
}

final class WindowListProbeDetachedUITests: WindowListProbeBase {
    override var mode: String { "detached" }
    @MainActor func testMeasure() throws { try measure() }
}
