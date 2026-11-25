import Foundation
import Testing
@testable import Lunetta

@Test func labelShowsVersionBuildAndCommit() {
    let info: [String: Any] = [
        "CFBundleShortVersionString": "0.1.0",
        "CFBundleVersion": "42",
        "LunettaCommit": "abc1234",
    ]
    #expect(BuildInfo.label(from: info) == "Lunetta 0.1.0 (42) abc1234")
}

@Test func appBundleCarriesCommit() {
    #expect(Bundle.main.object(forInfoDictionaryKey: "LunettaCommit") is String)
}
