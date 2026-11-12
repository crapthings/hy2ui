import Foundation

/// Exercises unified rule edits with in-memory legacy configuration and no application or networking services.
@main struct RuleListSmoke {
    static func main() throws {
        var configuration = RoutingConfiguration()
        configuration.directProcesses = ["WeChat", "WeChat", "/Applications/Example.app/"]
        configuration.directDomains = ["Example.COM", "legacy.example"]
        configuration.addressRules = [try AddressRule(target: "example.com", action: .proxy),
                                      try AddressRule(target: "192.168.1.42/24", action: .direct)]
        let rows = RuleListEntry.entries(in: configuration)
        precondition(rows.count == 4 && Set(rows.map(\.id)).count == rows.count)
        precondition(rows.last?.isFinal == true && rows.last?.type == "FINAL")
        precondition(rows.last?.value == "", "FINAL has no matching value")
        precondition(!rows.contains { $0.type.hasPrefix("PROCESS") })
        precondition(RuleEditorKind.allCases.allSatisfy { !$0.isProcess })
        let domain = rows.first { $0.value == "example.com" }!
        precondition(domain.policy == "FINAL", "explicit address rules must override legacy direct domains")
        let network = rows.first { $0.type == "IP-CIDR" }!
        precondition(network.value == "192.168.1.0/24")

        let original = configuration
        var invalid = RuleEditorDraft(entry: rows.first!)
        invalid.value = "bad/relative/path"
        do {
            try invalid.apply(to: &configuration)
            preconditionFailure("invalid rule edit unexpectedly succeeded")
        } catch { precondition(configuration == original, "failed edits must preserve the original rule") }

        var duplicate = RuleEditorDraft(entry: rows[1])
        duplicate.kind = .domain
        duplicate.value = "example.com"
        do {
            try duplicate.apply(to: &configuration)
            preconditionFailure("duplicate rule edit unexpectedly succeeded")
        } catch { precondition(configuration == original) }

        var edit = RuleEditorDraft(entry: domain)
        edit.action = .direct
        try edit.apply(to: &configuration)
        precondition(configuration.addressRules.first { $0.target == "example.com" }?.action == .direct)
        precondition(!configuration.directDomains.contains { (try? RoutingConfiguration.domain($0)) == "example.com" })
        let changed = configuration
        rows.last!.remove(from: &configuration)
        precondition(configuration == changed, "FINAL must not be deletable")

        var wrongKind = RuleEditorDraft(kind: .domain)
        wrongKind.value = "10.0.0.1"
        do {
            try wrongKind.apply(to: &configuration)
            preconditionFailure("domain editor accepted an IP rule")
        } catch { precondition(configuration == changed) }

        var ipv6 = RuleEditorDraft(kind: .network6)
        ipv6.value = "2001:db8::1"
        ipv6.action = .proxy
        try ipv6.apply(to: &configuration)
        precondition(RuleListEntry.entries(in: configuration).contains { $0.type == "IP-CIDR6" && $0.policy == "FINAL" })
        let encoded = try JSONEncoder().encode(configuration)
        let decoded = try JSONDecoder().decode(RoutingConfiguration.self, from: encoded)
        precondition(decoded == configuration, "legacy process data remains readable without exposing an editor")

        var exact = RuleEditorDraft(kind: .domainExact)
        exact.value = "exact.example"
        exact.preferences.comment = "Exact host"
        try exact.apply(to: &configuration)
        precondition(configuration.addressRules.last?.domainMatch == .exact)
        let oldAddress = Data(#"{"target":"legacy.example","action":"direct"}"#.utf8)
        let decodedAddress = try JSONDecoder().decode(AddressRule.self, from: oldAddress)
        precondition(decodedAddress.domainMatch == .suffix)
        let pac = try PACScript.generate(configuration: configuration, httpPort: 8080)
        precondition(pac.contains("hy2ExactDomains") && pac.contains("hy2CacheSize>=512"))
        configuration.rulePreferences["address:exact.example"] = RulePreferences(enabled: false)
        precondition(!configuration.activeRules.addressRules.contains { $0.target == "exact.example" })
        try configuration.validate()
        print("Unified rule projection, legacy deduplication, atomic edits and FINAL protection passed.")
    }
}
