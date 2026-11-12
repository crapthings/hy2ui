import Foundation
import Testing
@testable import Hy2Models

/// Verifies credentials remain data rather than injected proxy configuration.
@Test func credentialsCannotInjectConfiguration() throws {
    var profile = Profile()
    profile.host = "example.com"
    let password = "secret\nhttp:\n  listen: 0.0.0.0:80\n\"\\"
    let data = try profile.coreConfiguration(credentials: Credentials(password: password))
    let config = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(config["auth"] as? String == password)
    #expect((config["http"] as? [String: String])?["listen"] == "127.0.0.1:18080")
}

/// Verifies VPN configuration preserves IPv6 addressing without opening local proxies.
@Test func ipv6AndVPNConfiguration() throws {
    var profile = Profile()
    profile.host = "2001:db8::1"
    profile.systemProxyEnabled = false
    profile.enhancedModeEnabled = true
    let data = try profile.coreConfiguration(credentials: Credentials(password: "secret"))
    let config = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(config["server"] as? String == "[2001:db8::1]:443")
    #expect(config["http"] == nil)
    #expect(config["socks5"] == nil)
    #expect(config["tun"] == nil)
}

/// Rejects invalid server endpoints, duplicate proxy ports, and invalid DNS addresses.
@Test func invalidNetworkingConfigurationIsRejected() {
    for host in ["https://example.com", "example.com:443", "a b", "[::1]", ""] {
        var profile = Profile()
        profile.host = host
        #expect(throws: (any Error).self) { try profile.validate() }
    }
    var profile = Profile()
    profile.host = "example.com"
    profile.socksPort = profile.httpPort
    #expect(throws: (any Error).self) { try profile.validate() }
    profile.systemProxyEnabled = false
    profile.enhancedModeEnabled = true
    profile.dns = ["not-an-ip"]
    #expect(throws: (any Error).self) { try profile.validate() }
}

/// Verifies numeric server pinning preserves the configured TLS server name.
@Test func tunnelEndpointPreservesTLSNameWhilePinningAddress() throws {
    let config = try JSONSerialization.data(withJSONObject: ["server": "[::1]:443", "auth": "secret", "tls": ["sni": "vpn.example.com"]])
    let resolved = try CoreEndpoint.resolve(configuration: config)
    let object = try #require(JSONSerialization.jsonObject(with: resolved.configuration) as? [String: Any])
    #expect(resolved.address == "::1")
    #expect(object["server"] as? String == "[::1]:443")
    #expect((object["tls"] as? [String: String])?["sni"] == "vpn.example.com")
}

/// Keeps DIRECT startup independent of DNS and remote handshakes while preserving saved connection data.
@Test func directEndpointDoesNotResolveUnusedServer() throws {
    let input = Data(#"{"server":"unused-proxy.invalid:443","auth":"test","tls":{"sni":"unused-proxy.invalid"}}"#.utf8)
    let result = try CoreEndpoint.resolve(configuration: input, finalDirect: true)
    let core = try #require(JSONSerialization.jsonObject(with: result.configuration) as? [String: Any])
    #expect(result.address == "127.0.0.1")
    #expect(core["server"] as? String == "127.0.0.1:443")
    #expect(core["lazy"] as? Bool == true)
    #expect((core["tls"] as? [String: String])?["sni"] == "unused-proxy.invalid")
}
