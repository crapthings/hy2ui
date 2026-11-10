import Foundation

/// Restores proxy settings only while each coherent configuration group still belongs to Hy2UI.
public enum ProxyOwnership {
    /// Lists the enable, host, and port keys that must retain ownership together.
    private static let endpointGroups = [
        ["HTTPEnable", "HTTPProxy", "HTTPPort"],
        ["HTTPSEnable", "HTTPSProxy", "HTTPSPort"],
        ["SOCKSEnable", "SOCKSProxy", "SOCKSPort"]
    ]

    /// Restores owned endpoint groups and independent settings without combining them with external edits.
    public static func restore(current: [String: Any], original: [String: Any], installed: [String: Any]) -> [String: Any] {
        var result = current
        var independentKeys = Set(installed.keys)
        for group in endpointGroups {
            let managedKeys = group.filter { installed[$0] != nil }
            independentKeys.subtract(managedKeys)
            guard !managedKeys.isEmpty,
                  managedKeys.allSatisfy({ matches(current[$0], installed[$0]) }) else { continue }
            for key in managedKeys { result[key] = original[key] }
        }
        for key in independentKeys where matches(current[key], installed[key]) {
            result[key] = original[key]
        }
        return result
    }

    /// Compares existing property-list values while treating a removed setting as an ownership change.
    private static func matches(_ current: Any?, _ installed: Any?) -> Bool {
        guard let current, let installed else { return false }
        return NSDictionary(dictionary: ["value": current]).isEqual(to: ["value": installed])
    }
}
