import Foundation
import GlintCore

final class UserDefaultsStore: KeyValueStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func string(forKey key: String) -> String? { defaults.string(forKey: key) }

    func set(_ value: String?, forKey key: String) { defaults.set(value, forKey: key) }

    func bool(forKey key: String) -> Bool? { defaults.object(forKey: key) as? Bool }

    func set(_ value: Bool, forKey key: String) { defaults.set(value, forKey: key) }
}
