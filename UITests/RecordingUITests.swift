import AppKit
import AVFoundation
import XCTest

final class RecordingUITests: LunettaUITestCase {
    @MainActor func testRecordAreaThenStopFromTheMenuBarWritesAPlayableMP4OfTheSelectedSize() async throws {
        let scale = pointerScreen.backingScaleFactor
        let movie = try recordArea(movingThePointerThrough: true)
        try await assertPlayable(movie, size: CGSize(width: 200 * scale, height: 150 * scale))
        let audio = try await AVURLAsset(url: movie).loadTracks(withMediaType: .audio)
        XCTAssertTrue(audio.isEmpty, "system audio and microphone are off, yet \(movie.lastPathComponent) has \(audio.count) audio track(s)")
        XCTAssertFalse(stopRecordingButton.exists, "the menu bar timer stayed after the recording ended")
        XCTAssertFalse(recordingControl(AccessibilityID.stopRecordingControl).exists, "the recording controls stayed after the recording ended")
        XCTAssertTrue(app.images["Recording \(movie.lastPathComponent)"].waitForExistence(timeout: Self.captureTimeout),
                      "the recording didn't show up in the quick-access overlay")
        assertPNGCount(0)
    }

    @MainActor func testPauseAndResumeFromTheControlsThenStopJoinsThePartsIntoOneMP4() async throws {
        let scale = pointerScreen.backingScaleFactor
        let topLeft = startRecordingArea()
        movePointer(through: topLeft, for: 1)
        let pause = recordingControl(AccessibilityID.pauseRecording)
        center(of: pause).click()
        XCTAssertTrue(waitUntil(pause, hasLabel: "Resume"), "Pause didn't turn into Resume after pausing")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        center(of: pause).click()
        XCTAssertTrue(waitUntil(pause, hasLabel: "Pause"), "Resume didn't turn back into Pause after resuming")
        movePointer(through: topLeft, for: 1)
        center(of: recordingControl(AccessibilityID.stopRecordingControl)).click()

        let movie = try XCTUnwrap(waitForFile(withExtension: "mp4"), "no MP4 in \(saveFolder.path) after stopping a paused and resumed recording")
        XCTAssertTrue(app.images["Recording \(movie.lastPathComponent)"].waitForExistence(timeout: Self.captureTimeout),
                      "the joined recording didn't show up in the quick-access overlay")
        try await assertPlayable(movie, size: CGSize(width: 200 * scale, height: 150 * scale))
        let movies = try FileManager.default.contentsOfDirectory(at: saveFolder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "mp4" }
        XCTAssertEqual(movies.count, 1, "pausing left more than the one recording behind: \(movies.map(\.lastPathComponent))")
    }

    @MainActor func testDiscardFromTheControlsAsksForASecondClickThenLeavesNothing() throws {
        let topLeft = startRecordingArea()
        movePointer(through: topLeft, for: 1)
        let discard = recordingControl(AccessibilityID.discardRecording)
        center(of: discard).click()
        XCTAssertTrue(stopRecordingButton.exists, "one click on Discard ended the recording; it should ask for a second click")
        center(of: discard).click()

        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: stopRecordingButton)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: Self.captureTimeout), .completed, "the menu bar timer stayed after discarding")
        RunLoop.current.run(until: Date().addingTimeInterval(Self.noFileWait))
        let files = try FileManager.default.contentsOfDirectory(at: saveFolder, includingPropertiesForKeys: nil)
        XCTAssertTrue(files.isEmpty, "discarding left \(files.map(\.lastPathComponent)) in \(saveFolder.path)")
        XCTAssertEqual(app.images.matching(NSPredicate(format: "label BEGINSWITH 'Recording '")).count, 0, "a discarded recording got a quick-access card")
    }

    /// XCUITest waits about 6 s for the system to go idle after a drag (run 45727922838), longer than the countdown,
    /// so this drag goes straight through the event tap and the countdown is polled without XCTWaiter's 1 s interval.
    @MainActor func testEscapeDuringTheCountdownRecordsNothing() throws {
        press(.recordArea)
        waitForOverlay(after: .recordArea)
        let origin = overlay.frame.origin
        postDrag(from: CGPoint(x: origin.x + 100, y: origin.y + 100), to: CGPoint(x: origin.x + 300, y: origin.y + 250))
        let countdown = app.descendants(matching: .any).matching(identifier: AccessibilityID.recordingCountdown).firstMatch
        XCTAssertTrue(poll(within: TimeInterval(2)) { countdown.exists }, "no countdown within 2 s of selecting the area to record")
        pressEscape()
        XCTAssertTrue(poll(within: Self.captureTimeout) { !countdown.exists }, "Esc didn't close the countdown")
        // Past the 3 s the countdown would have run, so a recording that started anyway shows its timer.
        XCTAssertFalse(stopRecordingButton.waitForExistence(timeout: 4), "a recording started after Esc cancelled the countdown")
        let files = try FileManager.default.contentsOfDirectory(at: saveFolder, includingPropertiesForKeys: nil)
        XCTAssertTrue(files.isEmpty, "cancelling the countdown left \(files.map(\.lastPathComponent)) in \(saveFolder.path)")
    }

    /// Top-left global points, the same space as `screenPoint`.
    @MainActor private func postDrag(from start: CGPoint, to end: CGPoint) {
        let steps = 10
        let points = [start] + (1...steps).map { step in
            let progress = CGFloat(step) / CGFloat(steps)
            return CGPoint(x: start.x + (end.x - start.x) * progress, y: start.y + (end.y - start.y) * progress)
        }
        for (index, point) in points.enumerated() {
            let type: CGEventType = index == 0 ? .leftMouseDown : .leftMouseDragged
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    @MainActor private func poll(within timeout: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return true
    }

    @MainActor private func waitUntil(_ element: XCUIElement, hasLabel label: String) -> Bool {
        let labelled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
        return XCTWaiter.wait(for: [labelled], timeout: Self.captureTimeout) == .completed
    }
}

final class SystemAudioRecordingUITests: LunettaUITestCase {
    override var extraLaunchArguments: [String] { ["-recordSystemAudio", "YES"] }

    @MainActor func testRecordingWithSystemAudioOnHasAnAudioTrack() async throws {
        let movie = try recordArea(movingThePointerThrough: false)
        let audio = try await AVURLAsset(url: movie).loadTracks(withMediaType: .audio)
        XCTAssertEqual(audio.count, 1, "system audio is on, yet \(movie.lastPathComponent) has \(audio.count) audio track(s)")
    }
}

extension LunettaUITestCase {
    /// Long enough for several frames: SCStream only sends a frame when the region changes, and the pointer moves through it.
    static let recordingLength: TimeInterval = 2

    @MainActor var stopRecordingButton: XCUIElement {
        app.descendants(matching: .any).matching(identifier: AccessibilityID.stopRecording).firstMatch
    }

    @MainActor func recordingControl(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Drags out a 200 × 150 pt area 100 pt in from the overlay's top left corner and returns that corner.
    @MainActor @discardableResult func selectRecordingArea() -> CGPoint {
        let origin = overlay.frame.origin
        let topLeft = CGPoint(x: origin.x + 100, y: origin.y + 100)
        screenPoint(topLeft).press(forDuration: 0.1, thenDragTo: screenPoint(CGPoint(x: topLeft.x + 200, y: topLeft.y + 150)))
        assertOverlayClosed(after: .recordArea)
        return topLeft
    }

    /// Selects the area and waits out the countdown until the menu bar timer shows the recording runs.
    @MainActor func startRecordingArea() -> CGPoint {
        press(.recordArea)
        waitForOverlay(after: .recordArea)
        let topLeft = selectRecordingArea()
        XCTAssertTrue(stopRecordingButton.waitForExistence(timeout: Self.captureTimeout), "no timer in the menu bar while recording")
        return topLeft
    }

    @MainActor func movePointer(through topLeft: CGPoint, for duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        var step: CGFloat = 0
        while Date() < deadline {
            screenPoint(CGPoint(x: topLeft.x + 20 + step.truncatingRemainder(dividingBy: 160), y: topLeft.y + 75)).hover()
            step += 16
        }
    }

    /// Records a 200 × 150 pt area for `recordingLength`, stops from the menu bar timer and returns the MP4.
    @MainActor func recordArea(movingThePointerThrough movesPointer: Bool) throws -> URL {
        let topLeft = startRecordingArea()
        if movesPointer {
            movePointer(through: topLeft, for: Self.recordingLength)
        } else {
            RunLoop.current.run(until: Date().addingTimeInterval(Self.recordingLength))
        }
        center(of: stopRecordingButton).click()
        return try XCTUnwrap(waitForFile(withExtension: "mp4"), "no MP4 in \(saveFolder.path) after stopping the recording")
    }

    func assertPlayable(_ movie: URL, size: CGSize, file: StaticString = #filePath, line: UInt = #line) async throws {
        let asset = AVURLAsset(url: movie)
        let duration = try await asset.load(.duration)
        XCTAssertGreaterThan(duration.seconds, 0, "\(movie.lastPathComponent) doesn't play: its duration is \(duration.seconds) s", file: file, line: line)
        let track = try await asset.loadTracks(withMediaType: .video).first
        let natural = try await XCTUnwrap(track, "\(movie.lastPathComponent) has no video track", file: file, line: line).load(.naturalSize)
        XCTAssertEqual(natural, size, file: file, line: line)
    }

    @MainActor func waitForFile(withExtension ext: String) -> URL? {
        let deadline = Date().addingTimeInterval(Self.captureTimeout)
        while Date() < deadline {
            let files = (try? FileManager.default.contentsOfDirectory(at: saveFolder, includingPropertiesForKeys: nil)) ?? []
            if let file = files.first(where: { $0.pathExtension == ext }) { return file }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return nil
    }
}
