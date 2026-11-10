import Foundation

/// Removes desktop capture metadata before passing strict upstream configuration to an unprivileged core.
public enum DesktopCoreConfiguration {
    public static func coreOnly(_ data: Data) throws -> Data {
        let keys = ["desktopDirectProcesses", "desktopBypassLocalNetworks", "desktopAddressRules"]
        guard keys.contains(where: { data.range(of: Data($0.utf8)) != nil }) else { return data }
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return data }
        guard keys.contains(where: { object[$0] != nil }) else { return data }
        for key in keys { object.removeValue(forKey: key) }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
