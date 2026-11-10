import Foundation
import Testing
@testable import Hy2Models

/// Keeps pinned servers ahead of recent successful use and newest additions after persistence reload.
@Test @MainActor func sidebarOrderingPersistsPinsAndUse() throws {
    let suite = "Hy2UI-ordering-tests-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let profiles = (0..<5).map { _ in Profile() }
    let preferences = ServerListPreferences(defaults: defaults)
    #expect(preferences.sorted(profiles).map(\.id) == profiles.reversed().map(\.id))
    preferences.recordUse(profiles[0].id, at: Date(timeIntervalSince1970: 100))
    preferences.recordUse(profiles[1].id, at: Date(timeIntervalSince1970: 200))
    preferences.togglePin(profiles[2].id)
    let restored = ServerListPreferences(defaults: defaults)
    #expect(Array(restored.sorted(profiles).prefix(3)).map(\.id) == [profiles[2].id, profiles[1].id, profiles[0].id])
    restored.togglePin(profiles[2].id)
    #expect(restored.sorted(profiles).first?.id == profiles[1].id)
    restored.remove(profiles[1].id)
    #expect(restored.sorted(profiles).first?.id == profiles[0].id)
}
