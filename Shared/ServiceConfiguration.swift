import Foundation

/// Keeps device-wide capture and listener settings independent from the selected proxy server.
public struct ServiceConfiguration: Codable, Equatable, Sendable {
    public var systemProxyEnabled: Bool
    public var enhancedModeEnabled: Bool
    public var enhancedBackend: EnhancedBackend
    private var enhancedBackendSchema: Int?
    private var allowLAN: Bool?
    public var httpPort: Int
    public var socksPort: Int
    public var mtu: Int
    public var dns: [String]

    public init(profile: Profile) {
        systemProxyEnabled = profile.systemProxyEnabled
        enhancedModeEnabled = profile.enhancedModeEnabled
        enhancedBackend = profile.enhancedBackend
        #if HY2_NETWORK_EXTENSION
        enhancedBackendSchema = profile.enhancedBackend == .networkExtension ? 1 : nil
        #else
        enhancedBackendSchema = nil
        #endif
        allowLAN = profile.allowLAN
        httpPort = profile.httpPort
        socksPort = profile.socksPort
        mtu = profile.mtu
        dns = profile.dns
    }

    public func applying(to server: Profile) -> Profile {
        var result = server
        result.systemProxyEnabled = systemProxyEnabled
        let available = EnhancedBackend.allCases.contains(enhancedBackend)
            && (enhancedBackend != .networkExtension || enhancedBackendSchema == 1)
        result.enhancedModeEnabled = enhancedModeEnabled && available
        result.enhancedBackend = available ? enhancedBackend : .localTun
        result.allowLAN = allowLAN ?? false
        result.httpPort = httpPort
        result.socksPort = socksPort
        result.mtu = mtu
        result.dns = dns
        return result
    }
}
