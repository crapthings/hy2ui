import Foundation

/// Builds a credential-bearing runtime pool in memory, rejecting unsupported capture before serialization.
public enum ClientPoolConfiguration {
    public static func applying(to data: Data, group: ServerGroup, servers: [Profile], credentials: [UUID: Credentials], capabilities: CorePoolCapabilities) throws -> Data {
        guard capabilities.supports(group.kind), group.kind != .select else { throw ConfigurationError.invalid("当前核心不支持此服务器组类型。") }
        try group.validate(serverIDs: Set(servers.map(\.id)))
        var object = try DesktopCoreConfiguration.object(data)
        guard object["tun"] == nil, let _ = object["http"], var socks = object["socks5"] as? [String: Any] else {
            throw ConfigurationError.invalid("自动服务器组目前仅支持系统代理，请关闭增强模式。")
        }
        var lines: [String: Any] = [:]
        for id in group.members {
            guard var server = servers.first(where: { $0.id == id }), let secret = credentials[id] else {
                throw ConfigurationError.invalid("服务器组成员或认证信息不可用。")
            }
            server.systemProxyEnabled = true; server.enhancedModeEnabled = false
            var line = try DesktopCoreConfiguration.object(server.coreConfiguration(credentials: secret))
            line.removeValue(forKey: "http"); line.removeValue(forKey: "socks5")
            lines["server-" + id.uuidString.lowercased()] = line
        }
        let name = "group-" + group.id.uuidString.lowercased()
        let policy: [String: Any] = ["members": group.members.map { "server-" + $0.uuidString.lowercased() },
            "policy": CorePoolCapabilities.policy(for: group.kind), "toleranceMs": group.toleranceMs ?? 50, "holdSeconds": group.holdSeconds ?? 60]
        object["proxyPool"] = ["version": 1, "default": name, "lines": lines, "groups": [name: policy],
            "health": ["url": group.probeURL ?? "https://www.apple.com/library/test/success.html", "intervalSeconds": group.probeInterval ?? 30,
                       "timeoutSeconds": group.probeTimeout ?? 5, "failureThreshold": group.failureThreshold ?? 3, "recoveryThreshold": group.recoveryThreshold ?? 2, "parallel": 4]]
        socks["disableUdp"] = !capabilities.udp; object["socks5"] = socks
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
