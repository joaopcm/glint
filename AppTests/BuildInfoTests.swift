import Foundation
import Testing
@testable import Glint

@Test func labelShowsVersionBuildAndCommit() {
    let info: [String: Any] = [
        "CFBundleShortVersionString": "0.1.0",
        "CFBundleVersion": "42",
        "GlintCommit": "abc1234",
    ]
    #expect(BuildInfo.label(from: info) == "Glint 0.1.0 (42) abc1234")
}

@Test func appBundleCarriesCommit() {
    #expect(Bundle.main.object(forInfoDictionaryKey: "GlintCommit") is String)
}
