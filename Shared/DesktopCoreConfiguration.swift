import Foundation

/// Validates desktop capture metadata and separates it from configuration passed to upstream cores.
public enum DesktopCoreConfiguration {
    public static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConfigurationError.invalid("核心配置必须是 JSON 对象。")
        }
        return object
    }

    public static func bypassLocalNetworks(in data: Data) throws -> Bool {
        do {
            return try JSONDecoder().decode(CaptureMetadata.self, from: data).desktopBypassLocalNetworks
        } catch {
            throw ConfigurationError.invalid("核心配置的本地网络绕过设置无效。")
        }
    }

    public static func finalDirect(in data: Data) throws -> Bool {
        guard data.range(of: Data("desktopFinalDirect".utf8)) != nil else { return false }
        return try JSONDecoder().decode(FinalMetadata.self, from: data).desktopFinalDirect ?? false
    }

    public static func coreOnly(_ data: Data) throws -> Data {
        let keys = ["desktopDirectProcesses", "desktopBypassLocalNetworks", "desktopAddressRules", "desktopFinalDirect"]
        guard keys.contains(where: { data.range(of: Data($0.utf8)) != nil }) else { return data }
        var object = try Self.object(data)
        guard keys.contains(where: { object[$0] != nil }) else { return data }
        for key in keys { object.removeValue(forKey: key) }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private struct CaptureMetadata: Decodable {
        let desktopBypassLocalNetworks: Bool
    }

    private struct FinalMetadata: Decodable {
        let desktopFinalDirect: Bool?
    }
}
