import Foundation

/// Describes a process rule shortcut without treating default routing as an explicit direct rule.
public enum ProcessRoutingAction: String, CaseIterable, Sendable {
    case direct, defaultRules
    public var title: String {
        switch self { case .direct: "直连 · DIRECT"; case .defaultRules: "使用默认规则" }
    }
}

/// Represents one stable executable path rather than a transient PID or a truncated display name.
public struct ProcessRoutingTarget: Equatable, Sendable {
    public let path: String
    public init(path: String) throws {
        try ProcessRulePattern.validate(path)
        guard path.hasPrefix("/"), !path.hasSuffix("/"), !path.contains("*"), !path.contains("?") else {
            throw ConfigurationError.invalid("无法获取此进程的完整路径。")
        }
        self.path = path
    }
}

/// Applies process shortcuts to the same persisted patterns consumed by the native local TCP process matcher.
public enum ProcessRoutingPolicy {
    public static func matchingPatterns(for target: ProcessRoutingTarget, in configuration: RoutingConfiguration) -> [String] {
        configuration.activeRules.directProcesses.filter { ProcessRulePattern.matches($0, path: target.path) }
    }

    public static func action(for target: ProcessRoutingTarget, in configuration: RoutingConfiguration) -> ProcessRoutingAction {
        matchingPatterns(for: target, in: configuration).isEmpty ? .defaultRules : .direct
    }

    public static func set(_ action: ProcessRoutingAction, for target: ProcessRoutingTarget, in configuration: inout RoutingConfiguration) throws {
        var next = configuration
        switch action {
        case .direct:
            if matchingPatterns(for: target, in: next).isEmpty {
                if !next.directProcesses.contains(target.path) { next.directProcesses.append(target.path) }
                next.rulePreferences["process:" + target.path, default: RulePreferences()].enabled = true
            }
        case .defaultRules:
            let shared = matchingPatterns(for: target, in: next).filter { $0 != target.path }
            guard shared.isEmpty else {
                throw ConfigurationError.invalid("此进程受名称或应用规则覆盖，请在规则页修改该规则。")
            }
            next.directProcesses.removeAll { $0 == target.path }
            next.rulePreferences.removeValue(forKey: "process:" + target.path)
        }
        var check = next
        if check.mode == .externalPAC && check.pacURL.isEmpty { check.mode = .manual }
        try check.validate()
        configuration = next
    }
}
