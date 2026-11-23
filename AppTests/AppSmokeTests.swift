import Foundation
import Testing

@Test func hostedInGlintApp() {
    #expect(Bundle.main.bundleIdentifier == "com.joaopcm.glint")
}
