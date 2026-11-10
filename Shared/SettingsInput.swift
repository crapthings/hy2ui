import Foundation
import Darwin

/// Identifies the editable transport fields that commit independently on blur or return.
public enum SettingsField: Sendable {
    case mtu, dns, httpPort, socksPort
}

/// Validates complete settings input before changing a profile, including currently disabled modes.
public enum SettingsInput {
    public static func applying(_ text: String, field: SettingsField, to profile: Profile) throws -> Profile {
        var updated = profile
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch field {
        case .mtu:
            guard let value = Int(input), (1280...1500).contains(value) else {
                throw ConfigurationError.invalid("MTU 应在 1280–1500 之间。")
            }
            updated.mtu = value
        case .httpPort, .socksPort:
            guard let value = Int(input), (1024...65535).contains(value),
                  value != (field == .httpPort ? profile.socksPort : profile.httpPort) else {
                throw ConfigurationError.invalid("本地代理端口应不同，且在 1024–65535 之间。")
            }
            if field == .httpPort { updated.httpPort = value }
            else { updated.socksPort = value }
        case .dns:
            let servers = input.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard !servers.isEmpty, servers.count <= 8, servers.allSatisfy(isAddress) else {
                throw ConfigurationError.invalid("DNS 请填写有效的 IPv4 或 IPv6 地址。")
            }
            updated.dns = servers
        }
        return updated
    }

    private static func isAddress(_ value: String) -> Bool {
        var storage = in6_addr()
        return value.withCString { inet_pton(AF_INET, $0, &storage) == 1 || inet_pton(AF_INET6, $0, &storage) == 1 }
    }
}
