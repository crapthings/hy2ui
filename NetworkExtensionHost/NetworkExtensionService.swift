import Foundation
import NetworkExtension

/// Owns only this application's system VPN configuration and sends credentials through start options.
@MainActor
final class NetworkExtensionService: VPNConnectionControlling {
    var onStatus: ((VPNConnectionStatus) -> Void)?
    var onLog: ((String) -> Void)?
    private let activation = SystemExtensionActivator()
    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?
    private var generation = UUID()
    private var identifier: String {
        Bundle.main.object(forInfoDictionaryKey: "Hy2PacketProviderIdentifier") as? String ?? "dev.hy2ui.PacketTunnel"
    }

    private var captureEnabled: Bool {
        Bundle.main.object(forInfoDictionaryKey: "Hy2CaptureEnabled") as? String == "YES"
    }

    func load() async throws {
        guard captureEnabled else { return }
        let candidates = try await NETunnelProviderManager.loadAllFromPreferences()
        manager = candidates.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == identifier }
        observeStatus()
    }

    func start(profile: Profile, configuration: Data) async throws {
        guard captureEnabled, Bundle.main.object(forInfoDictionaryKey: "Hy2NetworkExtensionBuild") as? String == "YES" else {
            throw ProviderActivationError.captureDisabled
        }
        let token = UUID()
        generation = token
        onStatus?(.connecting)
        activation.onApprovalRequired = { [weak self] in self?.onLog?("请在系统设置中允许 Hy2UI 网络扩展。") }
        do {
            try await activation.activate(identifier: identifier)
            try current(token)
            let physical = try await PhysicalInterfaceResolver().resolve()
            try current(token)
            let input = try LocalTunConfiguration.fromCore(configuration, profile: profile)
            let options = try PacketTunnelConfiguration(input: input, physicalInterface: physical).encoded()
            let selected = manager ?? NETunnelProviderManager()
            let protocolConfiguration = NETunnelProviderProtocol()
            protocolConfiguration.providerBundleIdentifier = identifier
            protocolConfiguration.serverAddress = "Hy2UI"
            protocolConfiguration.providerConfiguration = ["schemaVersion": 1]
            protocolConfiguration.includeAllNetworks = false
            protocolConfiguration.enforceRoutes = false
            selected.protocolConfiguration = protocolConfiguration
            selected.localizedDescription = "Hy2UI Network Extension"
            selected.isOnDemandEnabled = false
            selected.isEnabled = true
            try await selected.saveToPreferences()
            try current(token)
            try await selected.loadFromPreferences()
            try current(token)
            manager = selected
            observeStatus()
            try selected.connection.startVPNTunnel(options: [PacketTunnelConfiguration.optionsKey: options as NSData])
            let start = ContinuousClock.now
            let deadline = start + .seconds(45)
            while selected.connection.status != .connected {
                try current(token)
                guard ContinuousClock.now < deadline else { throw ProviderActivationError.timedOut }
                if selected.connection.status == .invalid { throw ProviderActivationError.unavailable }
                if selected.connection.status == .disconnected && ContinuousClock.now > start + .seconds(2) {
                    throw ProviderActivationError.startFailed
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            onStatus?(.connected)
        } catch {
            if generation == token { manager?.connection.stopVPNTunnel() }
            throw error
        }
    }

    func stop() async throws {
        cancelPendingActivation()
        guard let manager else { onStatus?(.disconnected); return }
        manager.connection.stopVPNTunnel()
        let deadline = ContinuousClock.now + .seconds(15)
        while manager.connection.status != .disconnected && manager.connection.status != .invalid {
            guard ContinuousClock.now < deadline else { onStatus?(.recoveryRequired); throw ProviderActivationError.timedOut }
            try await Task.sleep(for: .milliseconds(100))
        }
        onStatus?(.disconnected)
    }

    func cancelPendingActivation() {
        generation = UUID()
        activation.cancel()
        manager?.connection.stopVPNTunnel()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func current(_ token: UUID) throws {
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
    }

    private func observeStatus() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        guard let connection = manager?.connection else { return }
        observer = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: connection, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch self.manager?.connection.status {
                case .connected: self.onStatus?(.connected)
                case .connecting: self.onStatus?(.connecting)
                case .disconnecting: self.onStatus?(.disconnecting)
                case .reasserting: self.onStatus?(.reasserting)
                case .invalid: self.onStatus?(.invalid)
                default: self.onStatus?(.disconnected)
                }
            }
        }
    }
}
