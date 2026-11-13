import Foundation

/// Compiles the visible rule list to the Rust client's native first-match routing contract.
public enum NativeClientRouting {
    public static func object(for saved: RoutingConfiguration) throws -> [String: Any] {
        let configuration = saved.activeRules
        let fallback = configuration.finalAction.rawValue
        if configuration.requestMode != .rules {
            return ["version": 1, "default": configuration.requestMode == .direct ? "direct" : "proxy", "rules": [String]()]
        }
        var rules: [String] = []
        for process in configuration.directProcesses {
            try validateProcess(process)
            rules.append("direct(\(process.hasPrefix("/") ? "process-path" : "process-name"):\(process))")
        }
        var addresses = Set<String>()
        for rule in configuration.addressRules {
            guard rule.domainMatch != .keyword else {
                throw ConfigurationError.invalid("当前核心不支持 DOMAIN-KEYWORD，请改为 DOMAIN 或 DOMAIN-SUFFIX。")
            }
            let matcher = rule.isDomain && rule.domainMatch == .suffix ? "suffix:" + rule.target : rule.target
            let action = rule.action == .proxy ? fallback : rule.action.rawValue
            rules.append("\(action)(\(matcher))")
            addresses.insert(rule.target)
        }
        for domain in configuration.directDomains {
            let domain = try RoutingConfiguration.domain(domain)
            if addresses.insert(domain).inserted { rules.append("direct(suffix:\(domain))") }
        }
        // Explicit user rules take priority; built-in local bypass precedes only FINAL.
        if configuration.bypassLocalNetworks {
            rules += ["direct(loopback)", "direct(lan)", "direct(localhost)", "direct(suffix:localhost)", "direct(suffix:local)", "direct(suffix:home.arpa)"]
        }
        return ["version": 1, "default": fallback, "rules": rules]
    }

    public static func applying(to data: Data, routing: RoutingConfiguration) throws -> Data {
        var object = try DesktopCoreConfiguration.object(DesktopCoreConfiguration.coreOnly(data))
        object["routing"] = try Self.object(for: routing)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    public static func validateProcess(_ value: String) throws {
        try ProcessRulePattern.validate(value)
        guard !value.contains(where: { "*?(),".contains($0) }), !value.hasSuffix("/") else {
            throw ConfigurationError.invalid("进程规则仅支持精确可执行文件名或完整路径，不支持通配符或应用目录。")
        }
    }
}
