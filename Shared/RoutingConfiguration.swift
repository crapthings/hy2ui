import Foundation

/// Selects fixed system proxies, a locally generated PAC script, or a user-supplied PAC URL.
public enum SystemProxyMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case native, manual, generatedPAC, externalPAC
    public var id: String { rawValue }
    public var title: String {
        switch self { case .native: "核心分流"; case .manual: "全局代理"; case .generatedPAC: "自动 PAC"; case .externalPAC: "PAC URL" }
    }
}

/// Persists a rule's enable switch and optional user comment independently of its matcher.
public struct RulePreferences: Codable, Equatable, Sendable {
    public var enabled = true
    public var comment = ""
    public init(enabled: Bool = true, comment: String = "") {
        self.enabled = enabled
        self.comment = comment
    }
}

/// Stores proxy selection and bypass preferences independently from server credentials.
public struct RoutingConfiguration: Codable, Equatable, Sendable {
    public var version = 1
    public var mode: SystemProxyMode = .native
    public var pacURL = ""
    public var directDomains: [String] = []
    public var bypassLocalNetworks = true
    public var directProcesses: [String] = []
    public var addressRules: [AddressRule] = []
    public var finalAction: AddressRuleAction = .proxy
    public var rulePreferences: [String: RulePreferences] = [:]
    public var requestMode = RequestRoutingMode.rules
    public var groups: [ServerGroup] = []
    public var rules: [RoutingRule] = []
    public var finalOutbound: OutboundTarget?

    public func preferences(for id: String) -> RulePreferences { rulePreferences[id] ?? RulePreferences() }

    /// Projects only enabled rules for runtime adapters while preserving the saved editor configuration.
    public var activeRules: RoutingConfiguration {
        var active = self
        active.directProcesses.removeAll { !preferences(for: "process:" + $0).enabled }
        active.addressRules.removeAll { !preferences(for: "address:" + $0.target).enabled }
        active.directDomains.removeAll { !preferences(for: "address:" + ((try? Self.domain($0)) ?? $0)).enabled }
        active.rulePreferences = [:]
        return active
    }
    public init() {}

    private enum CodingKeys: String, CodingKey { case version, mode, pacURL, directDomains, bypassLocalNetworks, directProcesses, addressRules, finalAction, rulePreferences, requestMode, groups, rules, finalOutbound }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        mode = try values.decode(SystemProxyMode.self, forKey: .mode)
        pacURL = try values.decode(String.self, forKey: .pacURL)
        directDomains = try values.decode([String].self, forKey: .directDomains)
        bypassLocalNetworks = try values.decode(Bool.self, forKey: .bypassLocalNetworks)
        directProcesses = try values.decodeIfPresent([String].self, forKey: .directProcesses) ?? []
        addressRules = try values.decodeIfPresent([AddressRule].self, forKey: .addressRules) ?? []
        finalAction = try values.decodeIfPresent(AddressRuleAction.self, forKey: .finalAction) ?? .proxy
        rulePreferences = try values.decodeIfPresent([String: RulePreferences].self, forKey: .rulePreferences) ?? [:]
        requestMode = try values.decodeIfPresent(RequestRoutingMode.self, forKey: .requestMode) ?? .rules
        groups = try values.decodeIfPresent([ServerGroup].self, forKey: .groups) ?? []
        finalOutbound = try values.decodeIfPresent(OutboundTarget.self, forKey: .finalOutbound)
        if let stored = try values.decodeIfPresent([RoutingRule].self, forKey: .rules) { rules = stored }
        else {
            for process in directProcesses {
                var rule = RoutingRule(); rule.kind = process.hasPrefix("/") ? .processPath : .processName; rule.value = process
                let preferences = preferences(for: "process:" + process)
                rule.enabled = preferences.enabled; rule.comment = preferences.comment; rules.append(rule)
            }
            var addresses = Set<String>()
            for old in addressRules {
                var rule = RoutingRule()
                rule.kind = old.isDomain ? (old.domainMatch == .exact ? .domain : old.domainMatch == .keyword ? .domainKeyword : .domainSuffix)
                    : (old.network?.isIPv6 == true ? .ipCIDR6 : .ipCIDR)
                rule.value = old.target; rule.outbound = old.action == .direct ? .direct : old.action == .reject ? .reject : .final
                let preferences = preferences(for: "address:" + old.target)
                rule.enabled = preferences.enabled; rule.comment = preferences.comment; rules.append(rule); addresses.insert(old.target)
            }
            for domain in directDomains {
                let normalized = try Self.domain(domain)
                guard addresses.insert(normalized).inserted else { continue }
                var rule = RoutingRule(); rule.value = normalized
                let preferences = preferences(for: "address:" + normalized)
                rule.enabled = preferences.enabled; rule.comment = preferences.comment; rules.append(rule)
            }
            if finalAction == .direct { finalOutbound = .direct }
        }
    }

    public func validate() throws {
        guard groups.count <= 32, rules.count <= 512, Set(groups.map(\.id)).count == groups.count,
              Set(rules.map(\.id)).count == rules.count, finalOutbound != .final else {
            throw ConfigurationError.invalid("服务器组、规则或默认出口无效。")
        }
        for rule in rules { try rule.validate() }
        guard version == 1, directDomains.count <= 128, directProcesses.count <= 64, addressRules.count <= 128, Set(addressRules.map(\.target)).count == addressRules.count else {
            throw ConfigurationError.invalid("分流配置版本或规则数量无效。")
        }
        guard rulePreferences.count <= 320, rulePreferences.allSatisfy({ $0.key.utf8.count <= 2048 && $0.value.comment.utf8.count <= 2048 }) else {
            throw ConfigurationError.invalid("规则备注过长。")
        }
        for domain in directDomains { _ = try Self.domain(domain) }
        for rule in addressRules { try rule.validate() }
        for pattern in directProcesses { try ProcessRulePattern.validate(pattern) }
        if mode == .externalPAC {
            guard let url = URL(string: pacURL), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host?.isEmpty == false, url.user == nil, url.password == nil, url.fragment == nil,
                  !pacURL.contains(where: { $0.isWhitespace || $0.isNewline }),
                  !pacURL.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  url.port.map({ (1...65535).contains($0) }) ?? true,
                  pacURL.utf8.count <= 4096 else { throw ConfigurationError.invalid("PAC URL 请填写有效的 HTTP 或 HTTPS 地址。") }
        }
    }

    public func validateCapture(systemProxy: Bool, enhanced: Bool, backend: EnhancedBackend) throws {
        guard !enhanced || EnhancedBackend.allCases.contains(backend) else {
            throw ConfigurationError.invalid("官方 CLI 仅支持本地 TUN。")
        }
        var active = self
        if !systemProxy || finalAction == .direct { active.mode = .manual }
        try active.validate()
        if mode == .native {
            if enhanced && (requestMode == .direct || (requestMode == .rules &&
                (!active.activeRules.directProcesses.isEmpty || !active.activeRules.addressRules.isEmpty ||
                 !active.activeRules.directDomains.isEmpty || finalAction != .proxy))) {
                throw ConfigurationError.invalid("macOS 增强模式尚不支持核心分流；请关闭增强模式，使用系统代理测试规则。")
            }
            if systemProxy { _ = try NativeClientRouting.object(for: self) }
            return
        }
        if (systemProxy || enhanced) && !active.activeRules.directProcesses.isEmpty {
            throw ConfigurationError.invalid("官方 CLI 不支持进程分流。")
        }
        if systemProxy && enhanced && mode != .manual && finalAction != .direct {
            throw ConfigurationError.invalid("使用 PAC 时请关闭增强模式，避免直连流量再次被接管。")
        }

    }

    public static func domain(_ input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty, value.utf8.count <= 253,
              value.utf8.allSatisfy({ ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 46 }),
              value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({
                  !$0.isEmpty && $0.utf8.count <= 63 && !$0.hasPrefix("-") && !$0.hasSuffix("-")
              }) else { throw ConfigurationError.invalid("直连域名请逐项填写域名，不包含协议、路径或通配符。") }
        return value
    }
}

/// Implements the filename, absolute-path and app-prefix pattern shapes used by Surge-style process rules.
public enum ProcessRulePattern {
    public static func validate(_ pattern: String) throws {
        guard !pattern.isEmpty, pattern.utf8.count <= 1024,
              !pattern.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              pattern == pattern.trimmingCharacters(in: .whitespacesAndNewlines),
              !pattern.contains(","), !pattern.contains("\\"),
              (!pattern.contains("/") || pattern.hasPrefix("/")) else {
            throw ConfigurationError.invalid("应用规则请填写进程名称或绝对路径，可使用 * 和 ?。")
        }
    }

    public static func matches(_ pattern: String, path: String) -> Bool {
        guard (try? validate(pattern)) != nil, path.hasPrefix("/") else { return false }
        if pattern.hasPrefix("/") && pattern.hasSuffix("/") { return path.hasPrefix(pattern) }
        let candidate = pattern.hasPrefix("/") ? path : String(path.split(separator: "/").last ?? "")
        let pattern = Array(pattern), value = Array(candidate)
        var p = 0, v = 0, star: Int?, restart = 0
        while v < value.count {
            if p < pattern.count && (pattern[p] == "?" || pattern[p] == value[v]) { p += 1; v += 1 }
            else if p < pattern.count && pattern[p] == "*" { star = p; p += 1; restart = v }
            else if let star { restart += 1; v = restart; p = star + 1 }
            else { return false }
        }
        while p < pattern.count && pattern[p] == "*" { p += 1 }
        return p == pattern.count
    }
}
