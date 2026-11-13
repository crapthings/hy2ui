import Foundation

/// Selects an explicit address-rule route independently from the default proxy decision.
public enum AddressRuleAction: String, Codable, CaseIterable, Sendable {
    case direct, proxy, reject
    public var title: String { switch self { case .direct: "直连"; case .proxy: "代理"; case .reject: "拒绝" } }
}

/// Selects the cached host lookup used by a domain address rule.
public enum DomainRuleMatch: String, Codable, Sendable {
    case suffix, exact, keyword
}

/// Stores a domain matcher or pre-parsed IP prefix and its explicit routing action.
public struct AddressRule: Codable, Equatable, Identifiable, Sendable {
    public let target: String
    public let action: AddressRuleAction
    public let domainMatch: DomainRuleMatch
    public var id: String { target }
    public let network: IPNetwork?
    public var isDomain: Bool { network == nil }
    public init(target: String, action: AddressRuleAction, domainMatch: DomainRuleMatch = .suffix) throws {
        let value = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedNetwork = try? IPNetwork(value)
        self.network = parsedNetwork
        if let network = parsedNetwork { self.target = network.cidr }
        else {
            guard !value.contains(":"), !value.contains("/"), !value.split(separator: ".").allSatisfy({ Int($0) != nil }) else { throw IPNetworkError.invalid }
            self.target = try RoutingConfiguration.domain(value)
        }
        self.action = action
        self.domainMatch = domainMatch
        guard isDomain || domainMatch == .suffix else { throw IPNetworkError.invalid }
    }
    private enum CodingKeys: String, CodingKey { case target, action, domainMatch }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(target: values.decode(String.self, forKey: .target),
                      action: values.decode(AddressRuleAction.self, forKey: .action),
                      domainMatch: values.decodeIfPresent(DomainRuleMatch.self, forKey: .domainMatch) ?? .suffix)
    }
    public func validate() throws {
        guard try Self(target: target, action: action, domainMatch: domainMatch).target == target else { throw IPNetworkError.invalid }
    }
}
