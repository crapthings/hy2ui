import Foundation
import NetworkExtension

/// Adapts Network Extension settings calls to the isolated provider coordinator contract.
final class ExperimentalNetworkExtensionSystem: ExperimentalProviderSystem {
    private weak var provider: NEPacketTunnelProvider?
    private let settings: NEPacketTunnelNetworkSettings
    let packetFlow: ExperimentalPacketFlow

    init(provider: NEPacketTunnelProvider, settings: NEPacketTunnelNetworkSettings) {
        self.provider = provider
        self.settings = settings
        self.packetFlow = NetworkExtensionPacketFlow(provider.packetFlow)
    }

    func installSettings(completion: @escaping (Result<Void, Error>) -> Void) {
        guard let provider else { completion(.failure(ExperimentalProviderError.providerUnavailable)); return }
        provider.setTunnelNetworkSettings(settings) { error in
            if let error { completion(.failure(error)) } else { completion(.success(())) }
        }
    }

    func clearSettings(completion: @escaping (Result<Void, Error>) -> Void) {
        guard let provider else { completion(.failure(ExperimentalProviderError.providerUnavailable)); return }
        provider.setTunnelNetworkSettings(nil) { error in
            if let error { completion(.failure(error)) } else { completion(.success(())) }
        }
    }

    func cancelTunnel(error: Error) { provider?.cancelTunnelWithError(error) }
}

/// Rejects real tunnel startup until endpoint protection and deployment are independently verified.
final class ExperimentalPacketTunnelProvider: NEPacketTunnelProvider {
    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        completionHandler(ExperimentalProviderError.protectionUnverified)
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}
