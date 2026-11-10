import Foundation

/// Selects fixed system proxies, a locally generated PAC script, or a user-supplied PAC URL.
public enum SystemProxyMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case manual, generatedPAC, externalPAC
    public var id: String { rawValue }
    public var title: String {
        switch self { case .manual: "全局代理"; case .generatedPAC: "自动 PAC"; case .externalPAC: "PAC URL" }
    }
}

/// Stores proxy selection and bypass preferences independently from server credentials.
public struct RoutingConfiguration: Codable, Equatable, Sendable {
    public var version = 1
    public var mode: SystemProxyMode = .manual
    public var pacURL = ""
    public var directDomains: [String] = []
    public var bypassLocalNetworks = true
    public var directProcesses: [String] = []
    public init() {}

    public func validate() throws {
        guard version == 1, directDomains.count <= 128, directProcesses.count <= 64 else {
            throw ConfigurationError.invalid("分流配置版本或规则数量无效。")
        }
        for domain in directDomains { _ = try Self.domain(domain) }
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
        var active = self
        if !systemProxy { active.mode = .manual }
        try active.validate()
        if systemProxy && enhanced && mode != .manual {
            throw ConfigurationError.invalid("使用 PAC 时请关闭增强模式，避免直连流量再次被接管。")
        }
        if !directProcesses.isEmpty && (systemProxy || !enhanced || backend != .localTun) {
            throw ConfigurationError.invalid("应用直连目前需要仅开启本地增强模式。")
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
