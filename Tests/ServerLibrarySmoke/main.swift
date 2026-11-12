import Foundation

/// Verifies server-library migration and selection using temporary files without touching the Keychain.
@main
private struct ServerLibrarySmoke {
    @MainActor static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hy2-library-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ProfileStore(directory: directory)
        try require(store.load().profiles.isEmpty, "clean install should have no placeholder server")
        var legacy = Profile()
        legacy.host = "legacy.example.com"
        let legacyURL = directory.appendingPathComponent("profile.json")
        try JSONEncoder().encode(legacy).write(to: legacyURL)
        let migrated = try store.load()
        try require(migrated.selected == legacy, "migration changed the existing identity")
        try require(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("servers.json").path), "read-only migration wrote files")
        var second = Profile()
        second.host = "second.example.com"
        var library = migrated
        library.upsert(second)
        let libraryURL = directory.appendingPathComponent("servers.json")
        try PersistedConfiguration.encodeLibrary(library).write(to: libraryURL)
        try store.select(legacy.id)
        try require(store.load().selected == legacy, "selection did not persist")
        try require(store.load().profiles.count == 2, "selection dropped another server")
        try PersistedConfiguration.encodeLibrary(ServerLibrary()).write(to: libraryURL)
        try require(store.load().profiles.isEmpty, "empty library resurrected the legacy server")
        try Data("invalid library".utf8).write(to: libraryURL)
        do {
            _ = try store.load()
            throw SmokeFailure(message: "corrupt library silently fell back to legacy data")
        } catch is ConfigurationError {} catch is DecodingError {} catch let error as NSError where error.domain == NSCocoaErrorDomain {}
        print("Server library migration, persistent selection, empty library and corruption checks passed without Keychain access.")
    }

    private static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw SmokeFailure(message: message) }
    }
}

/// Reports a failed file-only migration invariant without exposing server credentials.
private struct SmokeFailure: Error {
    let message: String
}
