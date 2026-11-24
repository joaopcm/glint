import Foundation
import GlintCore

final class UserDefaultsStore: KeyValueStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func string(forKey key: String) -> String? { defaults.string(forKey: key) }

    func set(_ value: String?, forKey key: String) { defaults.set(value, forKey: key) }

    func bool(forKey key: String) -> Bool? { has(key) ? defaults.bool(forKey: key) : nil }

    func set(_ value: Bool, forKey key: String) { defaults.set(value, forKey: key) }

    func double(forKey key: String) -> Double? { has(key) ? defaults.double(forKey: key) : nil }

    func set(_ value: Double, forKey key: String) { defaults.set(value, forKey: key) }

    private func has(_ key: String) -> Bool { defaults.object(forKey: key) != nil }
}
