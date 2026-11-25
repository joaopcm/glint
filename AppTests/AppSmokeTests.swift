import Foundation
import Testing

@Test func hostedInLunettaApp() {
    #expect(Bundle.main.bundleIdentifier == "com.joaopcm.lunetta")
}
