import Foundation
import Testing
@testable import Hy2Models

/// Migrates legacy VPN profiles to local enhanced mode without opening proxy listeners.
@Test func legacyVPNDefaultsToLocalEnhancedMode() throws {
    let profile = try PersistedConfiguration.decodeProfile(Data(#"{"host":"example.com","mode":"vpn"}"#.utf8))
    #expect(profile.enhancedModeEnabled)
    #expect(!profile.systemProxyEnabled)
    #expect(profile.enhancedBackend == .localTun)
}

/// Disables legacy extension capture without silently opting into administrator TUN.
@Test func independentCaptureSettingsRoundTrip() throws {
    var profile = Profile()
    profile.host = "example.com"
    profile.systemProxyEnabled = true
    profile.enhancedModeEnabled = true
    profile.enhancedBackend = .networkExtension
    let decoded = try PersistedConfiguration.decodeProfile(JSONEncoder().encode(profile))
    #if HY2_NETWORK_EXTENSION
    #expect(decoded.enhancedBackend == .networkExtension)
    #expect(decoded.systemProxyEnabled && decoded.enhancedModeEnabled)
    #else
    #expect(decoded.enhancedBackend == .localTun)
    #expect(decoded.systemProxyEnabled && !decoded.enhancedModeEnabled)
    #endif
}

/// Writes only independent switches so simultaneous capture never loses information in a legacy field.
@Test func currentProfileDoesNotWriteLegacyMode() throws {
    var profile = Profile()
    profile.systemProxyEnabled = true
    profile.enhancedModeEnabled = true
    let data = try JSONEncoder().encode(profile)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["mode"] == nil)
    #expect(object["systemProxyEnabled"] as? Bool == true)
    #expect(object["enhancedModeEnabled"] as? Bool == true)
}

/// Makes explicit independent switches authoritative even if an obsolete field is malformed.
@Test func currentCaptureChoicesIgnoreObsoleteMode() throws {
    for mode in ["123", "\"unknown\"", "\"vpn\""] {
        let data = Data("{\"systemProxyEnabled\":true,\"enhancedModeEnabled\":true,\"mode\":\(mode)}".utf8)
        let profile = try PersistedConfiguration.decodeProfile(data)
        #expect(profile.systemProxyEnabled && profile.enhancedModeEnabled)
    }
}

/// Retains independently saved switches when migrating a partially updated legacy profile.
@Test func partialCaptureChoicesUseLegacyOnlyForMissingSwitch() throws {
    let profile = try PersistedConfiguration.decodeProfile(Data(#"{"systemProxyEnabled":true,"mode":"vpn"}"#.utf8))
    #expect(profile.systemProxyEnabled && profile.enhancedModeEnabled)
    let enhanced = try PersistedConfiguration.decodeProfile(Data(#"{"enhancedModeEnabled":false,"mode":"vpn"}"#.utf8))
    #expect(!enhanced.systemProxyEnabled && !enhanced.enhancedModeEnabled)
}

/// Includes only the ordinary proxy listener configuration when both capture methods are selected.
@Test func combinedConfigurationKeepsLocalListenersWithoutCreatingRootTun() throws {
    var profile = Profile()
    profile.host = "example.com"
    profile.enhancedModeEnabled = true
    let config = try #require(JSONSerialization.jsonObject(with: profile.coreConfiguration(credentials: Credentials(password: "secret"))) as? [String: Any])
    #expect(config["http"] != nil)
    #expect(config["socks5"] != nil)
    #expect(config["tun"] == nil)
}

/// Rejects selecting no capture method and validates both configurations when both are selected.
@Test func independentModesValidateEnabledSettings() {
    var profile = Profile()
    profile.host = "example.com"
    profile.systemProxyEnabled = false
    #expect(throws: (any Error).self) { try profile.validate() }
    profile.systemProxyEnabled = true
    profile.enhancedModeEnabled = true
    profile.mtu = 1
    #expect(throws: (any Error).self) { try profile.validate() }
    profile.mtu = 1400
    profile.socksPort = profile.httpPort
    #expect(throws: (any Error).self) { try profile.validate() }
}

/// A new NE-capable build still requires an explicit new-schema selection before capture.
@Test func legacyNetworkExtensionProfileNeverAutoEnablesCapture() throws {
    var profile = Profile()
    profile.enhancedModeEnabled = true
    profile.enhancedBackend = .networkExtension
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
    object.removeValue(forKey: "enhancedBackendSchema")
    let restored = try JSONDecoder().decode(Profile.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(restored.enhancedBackend == .localTun)
    #expect(!restored.enhancedModeEnabled)
}
