import Foundation
import GlintCore
import Security

enum KeychainError: Error, LocalizedError {
    case status(OSStatus)
    case unreadableItem(service: String)

    var errorDescription: String? {
        switch self {
        case .status(let status):
            "\(SecCopyErrorMessageString(status, nil) as String? ?? "unknown error") (OSStatus \(status))"
        case .unreadableItem(let service):
            "the \(service) item has no account name or password data"
        }
    }
}

struct KeychainCredentialStore: CredentialStore {
    static let bucketService = "com.joaopcm.glint.bucket"

    let service: String

    func load() throws -> S3Credentials? {
        var query = itemQuery
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        guard let attributes = item as? [String: Any],
              let accessKeyID = attributes[kSecAttrAccount as String] as? String,
              let secret = attributes[kSecValueData as String] as? Data
        else { throw KeychainError.unreadableItem(service: service) }
        return S3Credentials(accessKeyID: accessKeyID, secretAccessKey: String(decoding: secret, as: UTF8.self))
    }

    func save(_ credentials: S3Credentials?) throws {
        guard let credentials else {
            let status = SecItemDelete(itemQuery as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
            return
        }
        let fields: [String: Any] = [
            kSecAttrAccount as String: credentials.accessKeyID,
            kSecValueData as String: Data(credentials.secretAccessKey.utf8),
        ]
        var status = SecItemUpdate(itemQuery as CFDictionary, fields as CFDictionary)
        if status == errSecItemNotFound {
            var item = itemQuery.merging(fields) { $1 }
            item[kSecAttrLabel as String] = "Glint bucket keys"
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    private var itemQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
    }
}
