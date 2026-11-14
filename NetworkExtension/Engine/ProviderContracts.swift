import Foundation

/// Exposes the packet engine operations needed by a provider lifecycle coordinator.
protocol ProviderEngine: AnyObject {
    func start(configuration: Data, completion: @escaping (Result<Void, Error>) -> Void)
    func attach(flow: TunnelPacketFlow, completion: @escaping (Result<Void, Error>) -> Void)
    func stop(completion: @escaping (Result<Void, Error>) -> Void)
}

/// Allows the existing packet adapter to serve as the provider's packet engine.
extension PacketAdapter: ProviderEngine {}

/// Abstracts system settings and cancellation so lifecycle behavior can be tested without a VPN.
protocol ProviderSystem: AnyObject {
    var packetFlow: TunnelPacketFlow { get }
    func installSettings(completion: @escaping (Result<Void, Error>) -> Void)
    func clearSettings(completion: @escaping (Result<Void, Error>) -> Void)
    func cancelTunnel(error: Error)
}

/// Describes lifecycle rejection without exposing configuration or credentials.
enum ProviderError: Error, Equatable {
    case busy
    case cancelled
    case cleanupIncomplete
    case protectionUnverified
    case providerUnavailable
}
