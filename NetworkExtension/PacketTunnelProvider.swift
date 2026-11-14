import Foundation
import NetworkExtension

/// Maps system network-settings operations to the independently tested provider coordinator.
final class PacketTunnelSystem: ProviderSystem {
    private weak var provider: NEPacketTunnelProvider?
    private let settings: NEPacketTunnelNetworkSettings
    let packetFlow: TunnelPacketFlow

    init(provider: NEPacketTunnelProvider, settings: NEPacketTunnelNetworkSettings) {
        self.provider = provider
        self.settings = settings
        self.packetFlow = NetworkExtensionPacketFlow(provider.packetFlow)
    }
    func installSettings(completion: @escaping (Result<Void, Error>) -> Void) {
        guard let provider else { completion(.failure(ProviderError.providerUnavailable)); return }
        provider.setTunnelNetworkSettings(settings) { error in
            completion(error.map { .failure($0) } ?? .success(()))
        }
    }
    func clearSettings(completion: @escaping (Result<Void, Error>) -> Void) {
        guard let provider else { completion(.failure(ProviderError.providerUnavailable)); return }
        provider.setTunnelNetworkSettings(nil) { error in
            completion(error.map { .failure($0) } ?? .success(()))
        }
    }
    func cancelTunnel(error: Error) { provider?.cancelTunnelWithError(error) }
}

/// Hosts one packet core; real capture requires an explicit signed-build acceptance switch.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let lifecycle = DispatchQueue(label: "dev.hy2ui.ne.lifecycle")
    private var coordinator: ProviderCoordinator?
    private var system: PacketTunnelSystem?
    private var stopTimer: DispatchSourceTimer?
    private var stopCompletions: [() -> Void] = []

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        guard Bundle.main.object(forInfoDictionaryKey: "Hy2CaptureEnabled") as? String == "YES" else {
            completionHandler(ProviderError.protectionUnverified)
            return
        }
        guard let data = options?[PacketTunnelConfiguration.optionsKey] as? Data else {
            completionHandler(PacketEngineError.invalidConfiguration)
            return
        }
        lifecycle.async {
            guard self.coordinator == nil else { completionHandler(ProviderError.busy); return }
            do {
                let configuration = try PacketTunnelConfiguration.decode(data)
                let settings = try PacketTunnelSettings.make(configuration)
                let system = PacketTunnelSystem(provider: self, settings: settings)
                let queue = self.lifecycle
                let coordinator = ProviderCoordinator(system: system, callbackQueue: queue,
                    engineFactory: { failure in
                        PacketAdapter(callbackQueue: queue, coreFactory: { try RustPacketCore(configuration: $0) }, onFailure: failure)
                    }, onCleanupFailure: { [weak self] _ in self?.cancelTunnelWithError(ProviderError.cleanupIncomplete) })
                self.system = system
                self.coordinator = coordinator
                coordinator.start(configuration: try configuration.coreConfiguration()) { result in
                    switch result {
                    case .success: completionHandler(nil)
                    case let .failure(error): completionHandler(error)
                    }
                }
            } catch { completionHandler(error) }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        lifecycle.async {
            guard let coordinator = self.coordinator else { completionHandler(); return }
            self.stopCompletions.append(completionHandler)
            if self.stopTimer != nil { return }
            let timer = DispatchSource.makeTimerSource(queue: self.lifecycle)
            self.stopTimer = timer
            timer.schedule(deadline: .now() + 12)
            timer.setEventHandler {
                // Keep the owner retained if Rust cleanup is stuck; never report it as a clean restart.
                self.cancelTunnelWithError(ProviderError.cleanupIncomplete)
                self.finishStopCallbacks()
            }
            timer.resume()
            coordinator.stop { result in
                if case .success = result { self.coordinator = nil; self.system = nil }
                else { self.cancelTunnelWithError(ProviderError.cleanupIncomplete) }
                self.finishStopCallbacks()
            }
        }
    }

    private func finishStopCallbacks() {
        stopTimer?.cancel()
        stopTimer = nil
        let completions = stopCompletions
        stopCompletions.removeAll()
        completions.forEach { $0() }
    }
}
