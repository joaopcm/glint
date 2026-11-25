import AppKit
import Testing

@Test func hostedInLunettaApp() {
    #expect(Bundle.main.bundleIdentifier == "com.joaopcm.lunetta")
}

@MainActor @Test func menuBarIconIsATemplateImage() throws {
    let image = try #require(NSImage(named: "MenuBarIcon"), "MenuBarIcon is missing from App/Assets.xcassets")
    #expect(image.isTemplate)
    #expect(image.size == NSSize(width: 18, height: 18))
}
