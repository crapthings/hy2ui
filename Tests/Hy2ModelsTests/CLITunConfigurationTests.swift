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
    for address in ["10.1.2.3", "127.0.0.1", "192.168.1.1", "169.254.1.1", "::", "::1", "fd00::1", "fe80::1"] {
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

/// Adds the fixed helper journal only when the trusted core advertises recovery support.
@Test func cliTunJournalIsExplicitAndOptional() throws {
    let input = LocalTunConfiguration(host: "203.0.113.8", port: 443, password: "secret")
    let legacy = try #require(JSONSerialization.jsonObject(with: CLITunConfiguration.make(input)) as? [String: Any])
    let legacyTun = try #require(legacy["tun"] as? [String: Any])
    #expect((legacyTun["route"] as? [String: Any])?["journal"] == nil)
    let journaled = try #require(JSONSerialization.jsonObject(with: CLITunConfiguration.make(input, routeJournalPath: LocalTunWire.routeJournalPath)) as? [String: Any])
    let tun = try #require(journaled["tun"] as? [String: Any])
    #expect((tun["route"] as? [String: Any])?["journal"] as? String == LocalTunWire.routeJournalPath)
    #expect(throws: (any Error).self) { try CLITunConfiguration.make(input, routeJournalPath: "relative.json") }
}

/// Reproduces the reported ::/128 collision using the actual helper-generated configuration.
@Test func cliTunNeverEmitsUnspecifiedIPv6HostRoute() throws {
    for host in ["203.0.113.8", "2001:db8::8"] {
        for bypass in [true, false] {
            let input = LocalTunConfiguration(host: host, port: 443, password: "fixture", bypassLocalNetworks: bypass)
            let object = try #require(JSONSerialization.jsonObject(with: CLITunConfiguration.make(input)) as? [String: Any])
            let tun = try #require(object["tun"] as? [String: Any])
            let route = try #require(tun["route"] as? [String: Any])
            let prefixes = try #require(route["ipv6"] as? [String])
            #expect(!prefixes.contains("::/128"))
            let networks = try prefixes.map(IPNetwork.init)
            if bypass {
                for address in ["::", "::1"] {
                    let target = try IPNetwork(address)
                    #expect(!networks.contains { $0.contains(target) })
                }
            }
            for address in ["::2", "2001:db8::123", "2606:4700:4700::1111"] {
                let target = try IPNetwork(address)
                #expect(networks.contains { $0.contains(target) })
            }
        }
    }
}

/// Keeps native interface prefixes distinct from the core synthetic DNS endpoints and pools.
@Test func cliTunInterfaceAddressesAreOutsideFakePools() throws {
    let input = LocalTunConfiguration(host: "203.0.113.8", port: 443, password: "fixture")
    let object = try #require(JSONSerialization.jsonObject(with: CLITunConfiguration.make(input)) as? [String: Any])
    let tun = try #require(object["tun"] as? [String: Any])
    let addresses = try #require(tun["address"] as? [String: String])
    for (key, pool) in [("ipv4", "198.18.0.0/15"), ("ipv6", "fd00:198:18::/96")] {
        let interface = try IPNetwork(#require(addresses[key]))
        let synthetic = try IPNetwork(pool)
        #expect(!interface.contains(synthetic) && !synthetic.contains(interface))
    }
}
