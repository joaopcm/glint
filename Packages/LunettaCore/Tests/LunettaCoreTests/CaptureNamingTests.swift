import Foundation
import Testing
@testable import LunettaCore

@Test func baseNameFormat() {
    let d = ISO8601DateFormatter().date(from: "2026-11-22T15:04:05Z")!
    #expect(CaptureNaming.baseName(for: d, timeZone: TimeZone(identifier: "UTC")!) == "Lunetta 2026-11-22 at 15.04.05")
}

@Test func noCollision() {
    let url = CaptureNaming.uniqueFileURL(in: URL(filePath: "/tmp"), baseName: "Lunetta x", ext: "png", exists: { _ in false })
    #expect(url.lastPathComponent == "Lunetta x.png")
}

@Test func collisionAppendsCounter() {
    let taken: Set = ["Lunetta x.png", "Lunetta x (2).png"]
    let url = CaptureNaming.uniqueFileURL(in: URL(filePath: "/tmp"), baseName: "Lunetta x", ext: "png", exists: { taken.contains($0.lastPathComponent) })
    #expect(url.lastPathComponent == "Lunetta x (3).png")
}
