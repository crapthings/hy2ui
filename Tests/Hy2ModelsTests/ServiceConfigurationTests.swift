import Foundation
import Testing
@testable import Hy2Models

/// Applies global capture settings across different endpoints without replacing their server identities.
@Test func serviceConfigurationPreservesEndpointIdentity() throws {
    var original = Profile()
    original.enhancedModeEnabled = true
    original.systemProxyEnabled = false
    original.httpPort = 19080
    original.socksPort = 19081
    original.dns = ["1.1.1.1"]
    var target = Profile()
    target.host = "second.example.com"
    target.name = "JP2"
    target.serverName = "tls.example.com"
    let configuration = ServiceConfiguration(profile: original)
    let restored = try JSONDecoder().decode(ServiceConfiguration.self, from: JSONEncoder().encode(configuration))
    let applied = restored.applying(to: target)
    #expect(applied.id == target.id && applied.host == target.host && applied.name == target.name)
    #expect(applied.serverName == target.serverName && applied.port == target.port)
    #expect(ServiceConfiguration(profile: applied) == configuration)
}

/// Keeps a saved extension backend from silently enabling administrator TUN on another selected server.
@Test func serviceConfigurationDisablesLegacyExtensionCapture() throws {
    var legacy = Profile()
    legacy.enhancedBackend = .networkExtension
    legacy.enhancedModeEnabled = true
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(ServiceConfiguration(profile: legacy))) as? [String: Any])
    object.removeValue(forKey: "enhancedBackendSchema")
    let restored = try JSONDecoder().decode(ServiceConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
    let applied = restored.applying(to: Profile())
    #expect(applied.enhancedBackend == .localTun)
    #expect(!applied.enhancedModeEnabled)
}
