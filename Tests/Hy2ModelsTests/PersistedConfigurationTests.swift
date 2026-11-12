import Foundation
import Testing
@testable import Hy2Models

/// Verifies missing fields in a legacy profile receive explicit migration defaults.
@Test func legacyProfileUsesDefaultsForNewSettings() throws {
    let identifier = UUID()
    let data = try JSONSerialization.data(withJSONObject: ["id": identifier.uuidString, "host": "vpn.example.com", "port": 8443])
    let profile = try PersistedConfiguration.decodeProfile(data)
    #expect(profile.id == identifier)
    #expect(profile.host == "vpn.example.com")
    #expect(profile.port == 8443)
    #expect(profile.systemProxyEnabled && !profile.enhancedModeEnabled)
    #expect(profile.httpPort == 18080)
    #expect(profile.socksPort == 11080)
    #expect(profile.mtu == 1400)
    #expect(profile.dns == Profile().dns)
}

/// Verifies a legacy credential payload can omit the optional obfuscation password.
@Test func legacyCredentialsSupplyOptionalSecretDefaults() throws {
    let data = Data(#"{"password":"old-secret"}"#.utf8)
    let credentials = try PersistedConfiguration.decodeCredentials(data)
    #expect(credentials == Credentials(password: "old-secret"))
}

/// Verifies current server-library envelopes preserve profiles and credentials across round trips.
@Test func versionedSettingsRoundTrip() throws {
    var profile = Profile()
    profile.host = "vpn.example.com"
    profile.systemProxyEnabled = false
    profile.enhancedModeEnabled = true
    let library = try ServerLibrary(profiles: [profile], selectedID: profile.id)
    let data = try PersistedConfiguration.encodeLibrary(library)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["version"] as? Int == 1)
    #expect(try PersistedConfiguration.decodeLibrary(data) == library)
    let credentials = Credentials(password: "secret\nquoted\"value", obfuscationPassword: "obfs")
    #expect(try PersistedConfiguration.decodeCredentials(PersistedConfiguration.encodeCredentials(credentials)) == credentials)
}

/// Keeps the retired versioned single-profile format readable without exposing a writer for it.
@Test func versionedSingleProfileRemainsReadable() throws {
    let data = Data(#"{"version":1,"value":{"host":"legacy.example.com"}}"#.utf8)
    #expect(try PersistedConfiguration.decodeProfile(data).host == "legacy.example.com")
}

/// Prevents a future envelope from being decoded or overwritten by the current application.
@Test func futureSettingsVersionIsRejectedBeforeOverwrite() {
    let profile = Data(#"{"version":2,"value":{"host":"future.example.com"}}"#.utf8)
    let credentials = Data(#"{"version":2,"value":{"password":"future-secret"}}"#.utf8)
    #expect(throws: (any Error).self) { try PersistedConfiguration.decodeProfile(profile) }
    #expect(throws: (any Error).self) { try PersistedConfiguration.decodeCredentials(credentials) }
    #expect(throws: (any Error).self) { try PersistedConfiguration.ensureSupportedVersion(profile) }
    #expect(throws: (any Error).self) { try PersistedConfiguration.ensureSupportedVersion(credentials) }
}

/// Permits explicit replacement of corrupt legacy data while keeping decoding failures visible.
@Test func corruptLegacySettingsCanBeReplaced() throws {
    let data = Data("invalid legacy JSON".utf8)
    #expect(throws: (any Error).self) { try PersistedConfiguration.decodeProfile(data) }
    try PersistedConfiguration.ensureSupportedVersion(data)
}

/// Rejects present fields with incompatible types rather than silently replacing them with defaults.
@Test func malformedLegacySettingsDoNotSilentlyDefault() {
    let data = Data(#"{"host":"vpn.example.com","port":"not-a-number"}"#.utf8)
    #expect(throws: (any Error).self) { try PersistedConfiguration.decodeProfile(data) }
}
