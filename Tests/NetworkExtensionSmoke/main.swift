import Foundation
import NetworkExtension

/// Verifies NE configuration and route values without saving preferences or applying settings.
@main
struct NetworkExtensionSmoke {
    static func main() throws {
        for host in ["203.0.113.8", "2001:db8::8"] {
            let input = LocalTunConfiguration(host: host, port: 443, serverName: "server.example",
                password: "fixture-only", obfuscationPassword: "obfs-fixture")
            let configuration = try PacketTunnelConfiguration(input: input, physicalInterface: "en1")
            let decoded = try PacketTunnelConfiguration.decode(configuration.encoded())
            let core = try JSONSerialization.jsonObject(with: decoded.coreConfiguration()) as! [String: Any]
            precondition(core["http"] == nil && core["socks5"] == nil && core["routing"] == nil)
            let tun = core["tun"] as! [String: Any]
            precondition(tun["route"] == nil && tun["session"] == nil && tun["dns"] == nil && tun["egress"] == nil)
            let quic = core["quic"] as! [String: Any]
            precondition((quic["sockopts"] as! [String: Any])["bindInterface"] as? String == "en1")
            let settings = try PacketTunnelSettings.make(configuration)
            precondition(settings.ipv4Settings?.includedRoutes?.count == 1)
            precondition(settings.ipv6Settings?.includedRoutes?.count == 1)
            precondition(settings.dnsSettings?.matchDomains == [""])
            if host.contains(":") {
                precondition(settings.ipv6Settings?.excludedRoutes?.contains(where: { $0.destinationAddress == host && $0.destinationNetworkPrefixLength == 128 }) == true)
            } else {
                precondition(settings.ipv4Settings?.excludedRoutes?.contains(where: { $0.destinationAddress == host && $0.destinationSubnetMask == "255.255.255.255" }) == true)
            }
        }
        let input = LocalTunConfiguration(host: "203.0.113.8", port: 443, serverName: "server.example", password: "fixture")
        for interface in ["lo0", "utun9", "ppp0", "awdl0", "", "en1/unsafe"] {
            do { _ = try PacketTunnelConfiguration(input: input, physicalInterface: interface); preconditionFailure("invalid interface accepted") }
            catch { }
        }
        for host in ["example.com", "127.0.0.1", "198.18.0.2", "fd00:198:18::1", "fe80::1", "::ffff:203.0.113.8"] {
            do {
                _ = try PacketTunnelConfiguration(input: LocalTunConfiguration(host: host, port: 443, serverName: "server.example", password: "fixture"), physicalInterface: "en1")
                preconditionFailure("non-bootstrap endpoint accepted")
            } catch { }
        }
        let valid = try PacketTunnelConfiguration(input: input, physicalInterface: "en1")
        var object = try JSONSerialization.jsonObject(with: valid.encoded()) as! [String: Any]
        object["schemaVersion"] = 2
        do { _ = try PacketTunnelConfiguration.decode(JSONSerialization.data(withJSONObject: object)); preconditionFailure("unknown schema accepted") }
        catch { }
        do { _ = try PacketTunnelConfiguration.decode(Data(repeating: 0, count: 65_537)); preconditionFailure("oversized configuration accepted") }
        catch { }
        print("NE configuration, endpoint exclusions, scoped core settings and schema limits passed without network changes.")
    }
}
