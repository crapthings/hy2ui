import Foundation
import Testing
@testable import Hy2Models

/// Verifies credential escaping and the supported upstream TUN schema without creating an interface.
@Test func cliTunConfigurationPreservesSecretsAndFrozenEndpoint() throws {
    let secret = "quoted\"\npassword\\value"
    let input = LocalTunConfiguration(host: "203.0.113.8", port: 443, serverName: "tls.example.com",
                                      password: secret, obfuscationPassword: "obfs")
    let object = try #require(JSONSerialization.jsonObject(with: CLITunConfiguration.make(input)) as? [String: Any])
    #expect(Set(object.keys) == ["server", "auth", "tls", "tun", "obfs"])
    #expect(object["server"] as? String == "203.0.113.8:443")
    #expect(object["auth"] as? String == secret)
    #expect((object["tls"] as? [String: String])?["sni"] == "tls.example.com")
    let tun = try #require(object["tun"] as? [String: Any])
    let routes = try #require(tun["route"] as? [String: Any])
    #expect(routes["ipv4Exclude"] as? [String] == ["203.0.113.8/32"])
    #expect(routes["ipv6Exclude"] as? [String] == [])
}

/// Ensures literal IPv6 endpoints retain brackets and their physical host exclusion.
@Test func cliTunIPv6EndpointHasCorrectAuthority() throws {
    let input = LocalTunConfiguration(host: "2001:db8::8", port: 443, serverName: "tls.example.com", password: "secret")
    let object = try #require(JSONSerialization.jsonObject(with: CLITunConfiguration.make(input)) as? [String: Any])
    #expect(object["server"] as? String == "[2001:db8::8]:443")
    let tun = try #require(object["tun"] as? [String: Any])
    let routes = try #require(tun["route"] as? [String: Any])
    #expect(routes["ipv6Exclude"] as? [String] == ["2001:db8::8/128"])
}

/// Rejects retired worker options and unresolved hostnames before launching privileged CLI code.
@Test func cliTunRejectsUnsupportedWorkerRequests() {
    let inputs = [
        LocalTunConfiguration(host: "example.com", port: 443, password: "secret"),
        LocalTunConfiguration(host: "203.0.113.8", port: 443, password: "secret", directProcesses: ["curl"]),
        LocalTunConfiguration(host: "203.0.113.8", port: 443, password: "secret", addressRules: ["direct,1.1.1.1"]),
        LocalTunConfiguration(host: "203.0.113.8", port: 443, password: "secret", finalDirect: true)
    ]
    for input in inputs {
        #expect(throws: (any Error).self) { try CLITunConfiguration.make(input) }
    }
}

/// Checks that local bypass never loses public or synthetic-DNS capture in either address family.
@Test func cliTunCapturePrefixesRespectLocalBypass() throws {
    let routes = try (CLITunConfiguration.captureRoutes(ipv6: false, bypass: true)
                     + CLITunConfiguration.captureRoutes(ipv6: true, bypass: true)).map(IPNetwork.init)
    for address in ["10.1.2.3", "127.0.0.1", "192.168.1.1", "169.254.1.1", "::1", "fd00::1", "fe80::1"] {
        let target = try IPNetwork(address)
        #expect(!routes.contains { $0.contains(target) })
    }
    for address in ["1.1.1.1", "198.18.4.166", "100.64.0.1", "2606:4700::1111", "::2"] {
        let target = try IPNetwork(address)
        #expect(routes.contains { $0.contains(target) })
    }
    #expect(try CLITunConfiguration.captureRoutes(ipv6: false, bypass: false).count == 2)
    #expect(try CLITunConfiguration.captureRoutes(ipv6: true, bypass: false).count == 2)
}
