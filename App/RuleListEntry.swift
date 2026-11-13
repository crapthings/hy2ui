import Foundation

/// Identifies the existing routing storage behind each unified rule-list row.
enum RuleListSource: Equatable {
    case process(String), address(AddressRule), final
}

/// Projects process and canonical address rules into one list with a protected FINAL row.
struct RuleListEntry: Identifiable, Equatable {
    let number: Int
    let source: RuleListSource

    var id: String {
        switch source {
        case let .process(pattern): return "process:" + pattern
        case let .address(rule): return "address:" + rule.target
        case .final: return "final"
        }
    }
    var isFinal: Bool { source == .final }
    var value: String {
        switch source {
        case let .process(pattern): return pattern
        case let .address(rule): return rule.target
        case .final: return ""
        }
    }
    var type: String {
        switch source {
        case let .process(pattern): return pattern.hasPrefix("/") ? "PROCESS-PATH" : "PROCESS-NAME"
        case let .address(rule):
            if rule.isDomain {
                switch rule.domainMatch {
                case .suffix: return "DOMAIN-SUFFIX"
                case .exact: return "DOMAIN"
                case .keyword: return "DOMAIN-KEYWORD"
                }
            }
            return rule.network?.isIPv6 == true ? "IP-CIDR6" : "IP-CIDR"
        case .final: return "FINAL"
        }
    }
    var policy: String {
        if case let .address(rule) = source, rule.action == .reject { return "REJECT" }
        if case let .address(rule) = source, rule.action == .proxy { return "FINAL" }
        return isFinal ? "FINAL" : "DIRECT"
    }

    static func entries(in configuration: RoutingConfiguration) -> [RuleListEntry] {
        var processes = Set<String>()
        var sources: [RuleListSource] = configuration.directProcesses.filter { processes.insert($0).inserted }.map { .process($0) }
        var addresses = Set<String>()
        for rule in configuration.addressRules where addresses.insert(rule.target).inserted {
            sources.append(.address(rule))
        }
        for domain in configuration.directDomains {
            if let rule = try? AddressRule(target: domain, action: .direct), addresses.insert(rule.target).inserted {
                sources.append(.address(rule))
            }
        }
        sources.append(.final)
        return sources.enumerated().map { RuleListEntry(number: $0.offset, source: $0.element) }
    }

    func remove(from configuration: inout RoutingConfiguration) {
        guard !isFinal else { return }
        configuration.rulePreferences.removeValue(forKey: id)
        switch source {
        case let .process(pattern): configuration.directProcesses.removeAll { $0 == pattern }
        case let .address(rule):
            configuration.addressRules.removeAll { $0.target == rule.target }
            configuration.directDomains.removeAll { (try? RoutingConfiguration.domain($0)) == rule.target }
        case .final: break
        }
    }
}

/// Lists only the editable rule types currently supported by the existing protocol adapter.
enum RuleEditorKind: String, CaseIterable, Identifiable {
    case process, processPath, domainExact, domain, domainKeyword, network, network6
    static var allCases: [RuleEditorKind] { [.domainExact, .domain, .network, .network6, .process, .processPath] }
    var id: String { rawValue }
    var isProcess: Bool { self == .process || self == .processPath }
    var isDomain: Bool { [.domainExact, .domain, .domainKeyword].contains(self) }
    var title: String {
        switch self {
        case .process: return "PROCESS-NAME"
        case .processPath: return "PROCESS-PATH"
        case .domainExact: return "DOMAIN"
        case .domain: return "DOMAIN-SUFFIX"
        case .domainKeyword: return "DOMAIN-KEYWORD"
        case .network: return "IP-CIDR"
        case .network6: return "IP-CIDR6"
        }
    }
    var domainMatch: DomainRuleMatch {
        self == .domainExact ? .exact : self == .domainKeyword ? .keyword : .suffix
    }
    var placeholder: String {
        switch self {
        case .process: return "WeChat"
        case .processPath: return "/Applications/WeChat.app/Contents/MacOS/WeChat"
        case .domainExact, .domain: return "example.com"
        case .domainKeyword: return "example"
        case .network: return "192.168.1.0/24"
        case .network6: return "2001:db8::/32"
        }
    }
    var help: String {
        switch self {
        case .process: return "精确匹配可执行文件名；需要支持进程规则的 dev 核心，仅限本机 HTTP/SOCKS TCP。"
        case .processPath: return "精确匹配可执行文件完整路径，不支持应用目录或通配符。"
        case .domainExact: return "仅匹配此域名。"
        case .domain: return "匹配此域名及其子域名。"
        case .domainKeyword: return "匹配域名中包含的关键词。"
        case .network: return "输入 IPv4 地址或 CIDR 网段。"
        case .network6: return "输入 IPv6 地址或 CIDR 网段。"
        }
    }
}

/// Validates rule edits before atomically replacing their original process or address storage.
struct RuleEditorDraft: Identifiable {
    let id = UUID()
    var original: RuleListEntry?
    var kind: RuleEditorKind
    var value = ""
    var action = AddressRuleAction.direct
    var preferences = RulePreferences()

    init(kind: RuleEditorKind = .domain, entry: RuleListEntry? = nil, preferences: RulePreferences = RulePreferences()) {
        self.preferences = preferences
        self.kind = kind
        original = entry
        if let entry {
            value = entry.value
            switch entry.source {
            case let .process(pattern): self.kind = pattern.hasPrefix("/") ? .processPath : .process
            case let .address(rule):
                if rule.isDomain {
                    self.kind = rule.domainMatch == .exact ? .domainExact : rule.domainMatch == .keyword ? .domainKeyword : .domain
                } else { self.kind = rule.network?.isIPv6 == true ? .network6 : .network }
                action = rule.action
            case .final: break
            }
        }
    }

    func apply(to configuration: inout RoutingConfiguration) throws {
        guard original?.isFinal != true else { return }
        let target = value.trimmingCharacters(in: .whitespacesAndNewlines)
        var next = configuration
        let processIndex = original.flatMap { entry in configuration.directProcesses.firstIndex(of: entry.value) }
        let addressIndex = original.flatMap { entry in configuration.addressRules.firstIndex { $0.target == entry.value } }
        original?.remove(from: &next)
        let newID: String
        if kind.isProcess {
            try NativeClientRouting.validateProcess(target)
            guard (kind == .processPath) == target.hasPrefix("/") else {
                throw ConfigurationError.invalid("进程名称或路径与规则类型不符。")
            }
            guard !next.directProcesses.contains(target) else { throw ConfigurationError.invalid("相同规则已存在。") }
            next.directProcesses.insert(target, at: min(processIndex ?? next.directProcesses.count, next.directProcesses.count))
            newID = "process:" + target
        } else {
            let rule = try AddressRule(target: target, action: action, domainMatch: kind.domainMatch)
            guard kind.isDomain == rule.isDomain && (rule.isDomain || (kind == .network6) == (rule.network?.isIPv6 == true)) else {
                throw ConfigurationError.invalid(kind.isDomain ? "请输入有效的域名。" : "请输入有效的 IPv4、IPv6 或 CIDR 网段。")
            }
            guard !next.addressRules.contains(where: { $0.target == rule.target }),
                  !next.directDomains.contains(where: { (try? RoutingConfiguration.domain($0)) == rule.target }) else {
                throw ConfigurationError.invalid("相同规则已存在。")
            }
            next.addressRules.insert(rule, at: min(addressIndex ?? next.addressRules.count, next.addressRules.count))
            newID = "address:" + rule.target
        }
        next.rulePreferences[newID] = preferences
        // Validate the complete draft before publishing any edits.
        var check = next
        if check.mode == .externalPAC && check.pacURL.isEmpty { check.mode = .manual }
        try check.validate()
        configuration = next
    }
}
