import AppKit
import AVFoundation
import XCTest

final class RecordingUITests: LunettaUITestCase {
    @MainActor func testRecordAreaThenStopFromTheMenuBarWritesAPlayableMP4OfTheSelectedSize() async throws {
        let scale = pointerScreen.backingScaleFactor
        let movie = try recordArea(movingThePointerThrough: true)
        let asset = AVURLAsset(url: movie)
        let duration = try await asset.load(.duration)
        XCTAssertGreaterThan(duration.seconds, 0, "\(movie.lastPathComponent) doesn't play: its duration is \(duration.seconds) s")
        let track = try await asset.loadTracks(withMediaType: .video).first
        let size = try await XCTUnwrap(track, "\(movie.lastPathComponent) has no video track").load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 200 * scale, height: 150 * scale))
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertTrue(audio.isEmpty, "system audio and microphone are off, yet \(movie.lastPathComponent) has \(audio.count) audio track(s)")
        XCTAssertFalse(stopRecordingButton.exists, "the stop button stayed in the menu bar after the recording ended")
        XCTAssertTrue(app.images["Recording \(movie.lastPathComponent)"].waitForExistence(timeout: Self.captureTimeout),
                      "the recording didn't show up in the quick-access overlay")
        assertPNGCount(0)
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

    /// Records a 200 × 150 pt area for `recordingLength`, stops from the menu bar and returns the MP4.
    @MainActor func recordArea(movingThePointerThrough movesPointer: Bool) throws -> URL {
        press(.recordArea)
        waitForOverlay(after: .recordArea)
        let origin = overlay.frame.origin
        let topLeft = CGPoint(x: origin.x + 100, y: origin.y + 100)
        screenPoint(topLeft).press(forDuration: 0.1, thenDragTo: screenPoint(CGPoint(x: topLeft.x + 200, y: topLeft.y + 150)))
        assertOverlayClosed(after: .recordArea)

        let stop = stopRecordingButton
        XCTAssertTrue(stop.waitForExistence(timeout: Self.captureTimeout), "no stop button in the menu bar while recording")
        let deadline = Date().addingTimeInterval(Self.recordingLength)
        var step: CGFloat = 0
        while Date() < deadline {
            if movesPointer {
                screenPoint(CGPoint(x: topLeft.x + 20 + step.truncatingRemainder(dividingBy: 160), y: topLeft.y + 75)).hover()
                step += 16
            } else {
                RunLoop.current.run(until: deadline)
            }
        }
        center(of: stop).click()
        return try XCTUnwrap(waitForFile(withExtension: "mp4"), "no MP4 in \(saveFolder.path) after stopping the recording")
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
