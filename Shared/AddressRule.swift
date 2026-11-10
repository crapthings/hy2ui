import Foundation

/// Selects an explicit address-rule route independently from the default proxy decision.
public enum AddressRuleAction: String, Codable, CaseIterable, Sendable {
    case direct, proxy
    public var title: String { self == .direct ? "直连" : "代理" }
}

/// Stores a canonical domain suffix or IP prefix and its explicit routing action.
public struct AddressRule: Codable, Equatable, Identifiable, Sendable {
    public let target: String
    public let action: AddressRuleAction
    public var id: String { target }
    public var network: IPNetwork? { try? IPNetwork(target) }
    public var isDomain: Bool { network == nil }
    public init(target: String, action: AddressRuleAction) throws {
        let value = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if let network = try? IPNetwork(value) { self.target = network.cidr }
        else {
            guard !value.contains(":"), !value.contains("/"), !value.split(separator: ".").allSatisfy({ Int($0) != nil }) else { throw IPNetworkError.invalid }
            self.target = try RoutingConfiguration.domain(value)
        }
        self.action = action
    }
    public func validate() throws {
        guard try Self(target: target, action: action).target == target else { throw IPNetworkError.invalid }
    }
}
