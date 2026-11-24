#if DEBUG
import Foundation
import GlintCore

// UI tests hand Debug builds the bucket keys here: a Keychain item the test runner adds makes Glint ask for access, and nobody answers on CI.
final class EnvironmentCredentialStore: CredentialStore {
    static let accessKeyIDVariable = "GLINT_UI_TEST_ACCESS_KEY_ID"
    static let secretAccessKeyVariable = "GLINT_UI_TEST_SECRET_ACCESS_KEY"

    private var credentials: S3Credentials?

    init?(environment: [String: String]) {
        guard let accessKeyID = environment[Self.accessKeyIDVariable], let secret = environment[Self.secretAccessKeyVariable] else {
            return nil
        }
        credentials = S3Credentials(accessKeyID: accessKeyID, secretAccessKey: secret)
    }

    func load() throws -> S3Credentials? { credentials }

    func save(_ credentials: S3Credentials?) throws { self.credentials = credentials }
}
#endif
