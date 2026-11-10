import Foundation
import Testing
@testable import Hy2Models

/// Preserves multiple independently configured identities through versioned persistence.
@Test func serverLibraryRoundTripsMultipleProfiles() throws {
    var first = Profile()
    first.host = "first.example.com"
    var second = Profile()
    second.host = "second.example.com"
    second.enhancedModeEnabled = true
    var library = ServerLibrary()
    library.upsert(first)
    library.upsert(second)
    try library.select(first.id)
    let data = try PersistedConfiguration.encodeLibrary(library)
    #expect(try PersistedConfiguration.decodeLibrary(data) == library)
    #expect(library.selected == first)
    #expect(!String(decoding: data, as: UTF8.self).contains("password"))
}

/// Rejects duplicate identities and missing selections instead of silently replacing servers.
@Test func serverLibraryRejectsInvalidIdentities() throws {
    let profile = Profile()
    #expect(throws: (any Error).self) { try ServerLibrary(profiles: [profile, profile], selectedID: profile.id) }
    #expect(throws: (any Error).self) { try ServerLibrary(profiles: [profile], selectedID: UUID()) }
    #expect(throws: (any Error).self) { try ServerLibrary(profiles: [profile]) }
    #expect(throws: (any Error).self) { try ServerLibrary(profiles: [], selectedID: profile.id) }
    let invalid = Data(#"{"profiles":[],"selectedID":"00000000-0000-0000-0000-000000000001"}"#.utf8)
    #expect(throws: (any Error).self) { try PersistedConfiguration.decodeLibrary(invalid) }
}

/// Preserves unselected servers when updating or removing another identity.
@Test func serverLibraryUpdatesAndRemovesByIdentity() throws {
    var first = Profile()
    let second = Profile()
    var library = try ServerLibrary(profiles: [first, second], selectedID: first.id)
    first.name = "Renamed"
    library.upsert(first)
    #expect(library.profiles.count == 2)
    #expect(library.profiles.first?.name == "Renamed")
    library.remove(second.id)
    #expect(library.selectedID == first.id)
    library.remove(first.id)
    #expect(library.selected == nil && library.profiles.isEmpty)
    #expect(throws: (any Error).self) { try library.select(second.id) }
}

/// Chooses the remaining server after deleting the currently selected one.
@Test func serverLibraryRemovalSelectsRemainingServer() throws {
    let first = Profile()
    let second = Profile()
    var library = try ServerLibrary(profiles: [first, second], selectedID: first.id)
    library.remove(first.id)
    #expect(library.selected == second)
}
