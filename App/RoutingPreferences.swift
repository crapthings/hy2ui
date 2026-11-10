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
            let value = try JSONDecoder().decode(RoutingConfiguration.self, from: data)
            try value.validate(); configuration = value
        } catch { writable = false; self.error = "无法读取分流配置，原记录已保留。" }
    }

    func setProcessAction(_ action: ProcessRoutingAction, for target: ProcessRoutingTarget) throws {
        try update { try ProcessRoutingPolicy.set(action, for: target, in: &$0) }
    }

    func update(_ change: (inout RoutingConfiguration) throws -> Void) throws {
        guard writable else { throw ConfigurationError.invalid("无法读取分流配置，原记录已保留。") }
        var next = configuration
        try change(&next)
        // An empty external URL can be edited without committing an invalid connection configuration.
        if next.mode == .externalPAC && next.pacURL.isEmpty {
            var check = next; check.mode = .manual; try check.validate()
        } else { try next.validate() }
        var persisted = next
        if persisted.mode == .externalPAC && persisted.pacURL.isEmpty { persisted.mode = .manual }
        defaults.set(try JSONEncoder().encode(persisted), forKey: Self.key)
        if configuration != next { revision += 1 }
        configuration = next; error = nil
    }
}
