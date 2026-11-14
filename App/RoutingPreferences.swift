import Foundation
import Observation

/// Persists validated routing preferences without changing a live connection or server credentials.
@MainActor @Observable
final class RoutingPreferences {
    private(set) var configuration = RoutingConfiguration()
    private(set) var error: String?
    private(set) var revision = 0
    private let defaults: UserDefaults
    private var writable = true
    private static let key = "routingConfiguration"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: Self.key) else { return }
        do {
            var value = try JSONDecoder().decode(RoutingConfiguration.self, from: data)
            value.mode = .native
            try value.validate()
            configuration = value
        } catch { writable = false; self.error = "无法读取分流配置，原记录已保留。" }
    }

    func update(_ change: (inout RoutingConfiguration) throws -> Void) throws {
        guard writable else { throw ConfigurationError.invalid("无法读取分流配置，原记录已保留。") }
        var next = configuration
        try change(&next)
        next.mode = .native
        try next.validate()
        defaults.set(try JSONEncoder().encode(next), forKey: Self.key)
        if configuration != next { revision += 1 }
        configuration = next; error = nil
    }
}
