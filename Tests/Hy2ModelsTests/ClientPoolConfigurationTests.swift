import Foundation
import Testing
@testable import Hy2Models

/// Keeps unsupported cores fail-closed and verifies passwords exist only in generated runtime lines.
@Test func automaticGroupConfigurationUsesIndependentCredentialsAndRejectsCapture() throws {
    var a = Profile(); a.host = "a.example"; a.name = "a"
    var b = Profile(); b.host = "b.example"; b.name = "b"
    var group = ServerGroup(); group.name = "Japan"; group.kind = .fallback
    group.members = [a.id, b.id]; group.selectedID = a.id
    let secrets = [a.id: Credentials(password: "secret-a", obfuscationPassword: ""), b.id: Credentials(password: "secret-b", obfuscationPassword: "")]
    let base = try a.coreConfiguration(credentials: secrets[a.id]!)
    let caps = CorePoolCapabilities(policies: ["fallback"])
    let result = try ClientPoolConfiguration.applying(to: base, group: group, servers: [a,b], credentials: secrets, capabilities: caps)
    let json = try DesktopCoreConfiguration.object(result)
    let pool = try #require(json["proxyPool"] as? [String: Any])
    let lines = try #require(pool["lines"] as? [String: [String: Any]])
    #expect(lines["server-" + a.id.uuidString.lowercased()]?["auth"] as? String == "secret-a")
    #expect(lines["server-" + b.id.uuidString.lowercased()]?["auth"] as? String == "secret-b")
    #expect(lines.values.allSatisfy { $0["http"] == nil && $0["socks5"] == nil })
    #expect((json["socks5"] as? [String: Any])?["disableUdp"] as? Bool == true)
    #expect(throws: (any Error).self) {
        try ClientPoolConfiguration.applying(to: base, group: group, servers: [a,b], credentials: secrets, capabilities: .unavailable)
    }
    #expect(throws: (any Error).self) {
        try ClientPoolConfiguration.applying(to: base, group: group, servers: [a,b], credentials: [a.id: secrets[a.id]!], capabilities: caps)
    }
    var capture = json; capture["tun"] = ["name": "forbidden"]
    #expect(throws: (any Error).self) {
        try ClientPoolConfiguration.applying(to: JSONSerialization.data(withJSONObject: capture), group: group, servers: [a,b], credentials: secrets, capabilities: caps)
    }
    let udpData = try ClientPoolConfiguration.applying(to: base, group: group, servers: [a,b], credentials: secrets, capabilities: CorePoolCapabilities(policies: ["fallback"], udp: true))
    #expect((try DesktopCoreConfiguration.object(udpData)["socks5"] as? [String: Any])?["disableUdp"] as? Bool == false)
    let stored = String(decoding: try JSONEncoder().encode(group), as: UTF8.self)
    #expect(!stored.contains("secret-a") && !stored.contains("secret-b"))
    let roundTrip = try JSONDecoder().decode(ServerGroup.self, from: JSONEncoder().encode(group))
    #expect(roundTrip == group)
}

/// Missing or incompatible pool capabilities preserve only the legacy manual-group UI.
@Test func poolCapabilitySchemaMustMatch() throws {
    let old = try CorePoolCapabilities.parse(Data(#"{"schema_version":1}"#.utf8))
    #expect(old.supports(.select)); #expect(!old.supports(.fallback))
    let current = Data(#"{"schema_version":1,"proxy_pool":{"schema_version":1,"config_key":"proxyPool","inbounds":["http-tcp","socks5-tcp"],"policies":["latency","fallback","target-affinity"],"health_probe":true,"udp":false,"tun":false}}"#.utf8)
    #expect(try CorePoolCapabilities.parse(current).supports(.urlTest))
    #expect(try CorePoolCapabilities.parse(current).supports(.loadBalance))
    var report = try JSONSerialization.jsonObject(with: current) as! [String: Any]
    var pool = report["proxy_pool"] as! [String: Any]
    pool["udp"] = true
    report["proxy_pool"] = pool
    #expect(try !CorePoolCapabilities.parse(JSONSerialization.data(withJSONObject: report)).udp)
    pool["inbounds"] = ["http-tcp", "socks5-tcp", "socks5-udp"]
    report["proxy_pool"] = pool
    #expect(try CorePoolCapabilities.parse(JSONSerialization.data(withJSONObject: report)).udp)

}
