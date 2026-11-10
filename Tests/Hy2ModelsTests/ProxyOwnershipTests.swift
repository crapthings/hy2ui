import Foundation
import Testing
@testable import Hy2Models

/// Verifies that another application's enabled proxy remains a coherent configuration.
@Test func proxyRestorePreservesExternallyChangedEndpoint() {
    let original: [String: Any] = ["HTTPEnable": 0, "ExceptionsList": ["*.local"]]
    let installed: [String: Any] = ["HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 18080]
    let current: [String: Any] = ["HTTPEnable": 1, "HTTPProxy": "other-proxy", "HTTPPort": 3128, "ExceptionsList": ["new.local"]]
    let restored = ProxyOwnership.restore(current: current, original: original, installed: installed)
    #expect(NSDictionary(dictionary: restored).isEqual(to: current))
}

/// Verifies that changing only a host preserves the otherwise matching endpoint settings.
@Test func proxyRestorePreservesGroupWhenOnlyHostChanges() {
    let original: [String: Any] = ["HTTPEnable": 0]
    let installed: [String: Any] = ["HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 18080]
    let current: [String: Any] = ["HTTPEnable": 1, "HTTPProxy": "other-proxy", "HTTPPort": 18080]
    let restored = ProxyOwnership.restore(current: current, original: original, installed: installed)
    #expect(NSDictionary(dictionary: restored).isEqual(to: current))
}

/// Verifies that a removed endpoint key prevents partial restoration of its group.
@Test func proxyRestorePreservesGroupWhenFieldWasRemoved() {
    let original: [String: Any] = ["SOCKSEnable": 0, "SOCKSProxy": "old", "SOCKSPort": 1080]
    let installed: [String: Any] = ["SOCKSEnable": 1, "SOCKSProxy": "127.0.0.1", "SOCKSPort": 11080]
    let current: [String: Any] = ["SOCKSEnable": 1, "SOCKSProxy": "127.0.0.1"]
    let restored = ProxyOwnership.restore(current: current, original: original, installed: installed)
    #expect(NSDictionary(dictionary: restored).isEqual(to: current))
}

/// Verifies that an unchanged endpoint returns exactly to its original settings.
@Test func proxyRestoreReturnsOriginalWhenNoExternalEditsExist() {
    let original: [String: Any] = ["HTTPEnable": 0, "HTTPProxy": "old", "HTTPPort": 3128]
    let installed: [String: Any] = ["HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 18080]
    let restored = ProxyOwnership.restore(current: installed, original: original, installed: installed)
    #expect(NSDictionary(dictionary: restored).isEqual(to: original))
}

/// Verifies that originally absent keys disappear without overwriting unrelated external settings.
@Test func proxyRestoreRemovesOriginallyAbsentKeysAndPreservesUnrelatedEdits() {
    let original: [String: Any] = ["ExceptionsList": ["*.local"]]
    let installed: [String: Any] = ["HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 18080]
    var current = installed
    current["ExceptionsList"] = ["new.local"]
    let restored = ProxyOwnership.restore(current: current, original: original, installed: installed)
    #expect(NSDictionary(dictionary: restored).isEqual(to: ["ExceptionsList": ["new.local"]]))
}

/// Verifies that endpoint ownership is independent across protocols and PAC discovery settings.
@Test func proxyRestoreHandlesProtocolGroupsAndIndependentSettingsSeparately() {
    let original: [String: Any] = ["HTTPEnable": 0, "HTTPSEnable": 0, "ProxyAutoConfigEnable": 1]
    let installed: [String: Any] = [
        "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 18080,
        "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 18080,
        "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0
    ]
    var current = installed
    current["HTTPPort"] = 3128
    current["ProxyAutoDiscoveryEnable"] = 1
    let restored = ProxyOwnership.restore(current: current, original: original, installed: installed)
    #expect(restored["HTTPEnable"] as? Int == 1)
    #expect(restored["HTTPProxy"] as? String == "127.0.0.1")
    #expect(restored["HTTPPort"] as? Int == 3128)
    #expect(restored["HTTPSEnable"] as? Int == 0)
    #expect(restored["HTTPSProxy"] == nil)
    #expect(restored["HTTPSPort"] == nil)
    #expect(restored["ProxyAutoConfigEnable"] as? Int == 1)
    #expect(restored["ProxyAutoDiscoveryEnable"] as? Int == 1)
}
