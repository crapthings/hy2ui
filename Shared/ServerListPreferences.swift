import Foundation
import Observation

/// Persists sidebar pins and successful-use dates without modifying server credentials.
@MainActor @Observable
public final class ServerListPreferences {
    /// Stores ordering metadata independently for one server identity.
    private struct Entry: Codable {
        var pinned = false
        var lastUsed: Date?
    }
    private var entries: [String: Entry]
    private let defaults: UserDefaults
    private static let key = "serverListPreferences"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }

    public func isPinned(_ id: UUID) -> Bool { entries[id.uuidString]?.pinned == true }

    public func togglePin(_ id: UUID) {
        var entry = entries[id.uuidString] ?? Entry()
        entry.pinned.toggle()
        entries[id.uuidString] = entry
        persist()
    }

    public func recordUse(_ id: UUID, at date: Date = Date()) {
        var entry = entries[id.uuidString] ?? Entry()
        entry.lastUsed = date
        entries[id.uuidString] = entry
        persist()
    }

    public func remove(_ id: UUID) {
        entries.removeValue(forKey: id.uuidString)
        persist()
    }

    public func sorted(_ profiles: [Profile]) -> [Profile] {
        profiles.enumerated().sorted { lhs, rhs in
            let left = entries[lhs.element.id.uuidString] ?? Entry()
            let right = entries[rhs.element.id.uuidString] ?? Entry()
            if left.pinned != right.pinned { return left.pinned }
            let leftUse = left.lastUsed ?? .distantPast
            let rightUse = right.lastUsed ?? .distantPast
            if leftUse != rightUse { return leftUse > rightUse }
            return lhs.offset > rhs.offset
        }.map(\.element)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: Self.key) }
    }
}
