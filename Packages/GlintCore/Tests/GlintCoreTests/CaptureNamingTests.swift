import Foundation
import Testing
@testable import GlintCore

@Test func baseNameFormat() {
    let d = ISO8601DateFormatter().date(from: "2026-11-22T15:04:05Z")!
    #expect(CaptureNaming.baseName(for: d, timeZone: TimeZone(identifier: "UTC")!) == "Glint 2026-11-22 at 15.04.05")
}

@Test func noCollision() {
    let url = CaptureNaming.uniqueFileURL(in: URL(filePath: "/tmp"), baseName: "Glint x", ext: "png", exists: { _ in false })
    #expect(url.lastPathComponent == "Glint x.png")
}

@Test func collisionAppendsCounter() {
    let taken: Set = ["Glint x.png", "Glint x (2).png"]
    let url = CaptureNaming.uniqueFileURL(in: URL(filePath: "/tmp"), baseName: "Glint x", ext: "png", exists: { taken.contains($0.lastPathComponent) })
    #expect(url.lastPathComponent == "Glint x (3).png")
}
