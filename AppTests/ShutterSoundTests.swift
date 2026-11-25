import AppKit
import Testing
@testable import Lunetta

@MainActor @Test func macOSShipsTheShutterSoundWherePlayLooksForIt() throws {
    let sound = try #require(NSSound(contentsOf: ShutterSound.systemFile, byReference: true), "no sound at \(ShutterSound.systemFile.path)")
    #expect(sound.duration > 0)
}
