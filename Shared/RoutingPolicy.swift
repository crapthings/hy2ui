import Foundation

/// Identifies a rule's outbound independently of editable server and group names.
public enum OutboundTarget: Codable, Equatable, Hashable, Sendable {
    case direct, reject, server(UUID), group(UUID), final
    public func title(servers: [Profile], groups: [ServerGroup]) -> String {
        switch self {
        case .direct: "DIRECT"
        case .reject: "REJECT"
        case .final: "FINAL"
        case let .server(id): servers.first { $0.id == id }?.name ?? "服务器已不存在"
        case let .group(id): groups.first { $0.id == id }?.name ?? "服务器组已不存在"
        }
    }
    public var tag: String {
        switch self {
        case .direct: "DIRECT"
        case .reject: "REJECT"
        case .final: "hy2-final"
        case let .server(id): "server-" + id.uuidString.lowercased()
        case let .group(id): "group-" + id.uuidString.lowercased()
        }
    }
}

/// Selects rule-based routing, a single default outbound, or unconditional direct connections.
public enum RequestRoutingMode: String, Codable, CaseIterable, Sendable {
    case rules, global, direct
    public var title: String {
        switch self { case .rules: "规则分流"; case .global: "全局代理"; case .direct: "直连" }
    }
}

/// Selects the routing engine's group membership strategy without changing Hy2 transport implementations.
public enum ServerGroupKind: String, Codable, CaseIterable, Sendable {
    case select, urlTest = "url-test", fallback, loadBalance = "load-balance"
    public var title: String {
        switch self { case .select: "手动选择"; case .urlTest: "自动测速"; case .fallback: "故障切换"; case .loadBalance: "负载均衡" }
    }
}

/// Stores one flat server group with stable member identities and an explicit manual selection.
public struct ServerGroup: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var name = "新服务器组"
    public var kind = ServerGroupKind.select
    public var members: [UUID] = []
    public var selectedID: UUID?
    public init() {}
    public func validate(serverIDs: Set<UUID>) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 128,
              !members.isEmpty, members.count <= 64, Set(members).count == members.count,
              members.allSatisfy(serverIDs.contains), selectedID.map(members.contains) ?? true else {
            throw ConfigurationError.invalid("服务器组名称、成员或当前选择无效。")
        }
    }
}

/// Lists ordered domain, IP and application matchers supported by the independent routing engine.
public enum RoutingRuleKind: String, Codable, CaseIterable, Sendable {
    case domain = "DOMAIN", domainSuffix = "DOMAIN-SUFFIX", domainKeyword = "DOMAIN-KEYWORD"
    case ipCIDR = "IP-CIDR", ipCIDR6 = "IP-CIDR6", processName = "PROCESS-NAME", processPath = "PROCESS-PATH"
    public var isProcess: Bool { self == .processName || self == .processPath }
}

/// Stores one ordered routing decision including its destination, enabled state and user comment.
public struct RoutingRule: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var kind = RoutingRuleKind.domainSuffix
    public var value = ""
    public var outbound = OutboundTarget.direct
    public var enabled = true
    public var comment = ""
    public init() {}
    public func validate() throws {
        guard !value.isEmpty, value.utf8.count <= 1024, comment.utf8.count <= 2048,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines), !value.contains(","),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ConfigurationError.invalid("规则匹配值或备注无效。")
        }
        switch kind {
        case .domain, .domainSuffix, .domainKeyword: _ = try RoutingConfiguration.domain(value)
        case .ipCIDR, .ipCIDR6:
            let network = try IPNetwork(value)
            guard network.isIPv6 == (kind == .ipCIDR6) else { throw IPNetworkError.invalid }
        case .processName, .processPath:
            try ProcessRulePattern.validate(value)
            guard value.hasPrefix("/") == (kind == .processPath) else {
                throw ConfigurationError.invalid("进程名称或路径与规则类型不符。")
            }
        }
    }
    public var engineMatcher: String {
        if kind.isProcess && (value.contains("*") || value.contains("?") || value.hasSuffix("/")) {
            var expression = NSRegularExpression.escapedPattern(for: value)
                .replacingOccurrences(of: "\\*", with: ".*").replacingOccurrences(of: "\\?", with: ".")
            if value.hasSuffix("/") { expression += ".*" }
            return "\(kind == .processPath ? "PROCESS-PATH-REGEX" : "PROCESS-NAME-REGEX"),^\(expression)$"
        }
        return "\(kind.rawValue),\(value)"
    }
}
