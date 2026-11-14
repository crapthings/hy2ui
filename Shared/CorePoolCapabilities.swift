import Foundation

/// Validates the versioned proxy pool capability contract without inferring features from release names.
public struct CorePoolCapabilities: Equatable, Sendable {
    public let policies: Set<String>
    public let udp: Bool
    public static let unavailable = CorePoolCapabilities(policies: [])
    public init(policies: Set<String>, udp: Bool = false) { self.policies = policies; self.udp = udp }
    public static func parse(_ data: Data) throws -> Self {
        guard data.count <= 65_536,
              let report = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              report["schema_version"] as? Int == 1,
              let pool = report["proxy_pool"] as? [String: Any], pool["schema_version"] as? Int == 1,
              pool["config_key"] as? String == "proxyPool",
              pool["health_probe"] as? Bool == true,
              let udp = pool["udp"] as? Bool, pool["tun"] as? Bool == false,
              let inbounds = pool["inbounds"] as? [String], inbounds.contains("http-tcp"), inbounds.contains("socks5-tcp"),
              let policies = pool["policies"] as? [String], policies.count <= 16 else { return .unavailable }
        return Self(policies: Set(policies), udp: udp && inbounds.contains("socks5-udp"))
    }
    public func supports(_ kind: ServerGroupKind) -> Bool {
        kind == .select || policies.contains(Self.policy(for: kind))
    }
    public static func policy(for kind: ServerGroupKind) -> String {
        switch kind { case .select: "manual"; case .urlTest: "latency"; case .fallback: "fallback"; case .loadBalance: "target-affinity" }
    }
}
