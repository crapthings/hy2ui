import Foundation

/// Keeps device-wide capture and listener settings independent from the selected proxy server.
public struct ServiceConfiguration: Codable, Equatable, Sendable {
    public var systemProxyEnabled: Bool
    public var enhancedModeEnabled: Bool
    public var enhancedBackend: EnhancedBackend
    public var httpPort: Int
    public var socksPort: Int
    public var mtu: Int
    public var dns: [String]

    public init(profile: Profile) {
        systemProxyEnabled = profile.systemProxyEnabled
        enhancedModeEnabled = profile.enhancedModeEnabled
        enhancedBackend = profile.enhancedBackend
        httpPort = profile.httpPort
        socksPort = profile.socksPort
        mtu = profile.mtu
        dns = profile.dns
    }

    public func applying(to server: Profile) -> Profile {
        var result = server
        result.systemProxyEnabled = systemProxyEnabled
        result.enhancedModeEnabled = enhancedModeEnabled && enhancedBackend == .localTun
        result.enhancedBackend = .localTun
        result.httpPort = httpPort
        result.socksPort = socksPort
        result.mtu = mtu
        result.dns = dns
        return result
    }
}
