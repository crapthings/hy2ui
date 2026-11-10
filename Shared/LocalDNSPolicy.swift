import Foundation

/// Builds bounded supplemental DNS domains from existing physical-network search suffixes.
public enum LocalDNSPolicy {
    public static func domains(search: [String], includeHome: Bool = true) -> [String] {
        var values = Set(includeHome ? ["home.arpa"] : [])
        for input in search.prefix(32) {
            let value = input.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard !value.isEmpty, value.utf8.count <= 253,
                  value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ label in
                      !label.isEmpty && label.utf8.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-") && label.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 })
                  }) else { continue }
            values.insert(value)
        }
        return values.sorted()
    }
    public static func servers(_ values: [String]) -> [String] {
        values.prefix(8).filter { value in
            guard let network = try? IPNetwork(value), !value.contains("/") else { return false }
            return !(try! IPNetwork("198.18.0.0/15")).contains(network) && !(try! IPNetwork("127.0.0.0/8")).contains(network) && network.address != "::1"
        }
    }
}
