import Foundation
import NetworkExtension
import SystemExtensions

/// Registers the VPN extension and controls its system-managed tunnel connection.
@MainActor
final class VPNService: NSObject, OSSystemExtensionRequestDelegate {
    private var manager: NETunnelProviderManager?
    private let activation = CancellableRequest()
    private var activationRequest: (id: UUID, request: OSSystemExtensionRequest)?
    private var observer: NSObjectProtocol?
    var onStatus: ((NEVPNStatus) -> Void)?
    var onLog: ((String) -> Void)?
    private func extensionIdentifier() throws -> String {
        guard let identifier = Bundle.main.bundleIdentifier, !identifier.isEmpty else {
            throw ConfigurationError.invalid("应用缺少 Bundle ID，请重新构建或下载应用。")
        }
        return identifier + ".tunnel"
    }

    override init() {
        super.init()
        observer = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] notification in
            Task { @MainActor in
                guard let self, let connection = notification.object as? NEVPNConnection,
                      connection === self.manager?.connection else { return }
                self.onStatus?(connection.status)
                if connection.status == .disconnected {
                    connection.fetchLastDisconnectError { error in
                        guard let error else { return }
                        Task { @MainActor in self.onLog?("VPN：\(error.localizedDescription)") }
                    }
                }
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func load() async throws {
        let extensionID = try extensionIdentifier()
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        manager = managers.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == extensionID }
        if let manager { onStatus?(manager.connection.status) }
    }

    func start(profile: Profile, configuration: Data) async throws {
        try Task.checkCancellation()
        try await activate()
        try Task.checkCancellation()
        try await load()
        try Task.checkCancellation()
        let selected = manager ?? NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = try extensionIdentifier()
        proto.serverAddress = profile.serverAddress
        proto.disconnectOnSleep = false
        selected.protocolConfiguration = proto
        selected.localizedDescription = "Hy2UI"
        selected.isEnabled = true
        selected.isOnDemandEnabled = false
        try await selected.saveToPreferences()
        try Task.checkCancellation()
        try await selected.loadFromPreferences()
        try Task.checkCancellation()
        manager = selected
        guard let session = selected.connection as? NETunnelProviderSession else {
            throw ConfigurationError.invalid("无法创建 VPN 会话。")
        }
        // Credentials travel only in the start message; never in persisted VPN preferences.
        try session.startTunnel(options: [TunnelWire.configuration: configuration as NSData,
            TunnelWire.mtu: NSNumber(value: profile.mtu), TunnelWire.dns: profile.dns as NSArray])
    }

    func cancelPendingActivation() {
        activation.cancel()
        activationRequest = nil
    }

    func stopAndWait() async throws {
        cancelPendingActivation()
        guard let connection = manager?.connection else { return }
        if connection.status == .disconnected || connection.status == .invalid { return }
        connection.stopVPNTunnel()
        let deadline = ContinuousClock.now + .seconds(10)
        while connection.status != .disconnected && connection.status != .invalid {
            guard ContinuousClock.now < deadline else {
                throw ConfigurationError.invalid("VPN 尚未完成断开，请稍后重试。")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func activate() async throws {
        let extensionID = try extensionIdentifier()
        let id = UUID()
        defer { if activationRequest?.id == id { activationRequest = nil } }
        try await activation.wait(id: id) { id in
            let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: extensionID, queue: .main)
            request.delegate = self
            activationRequest = (id, request)
            OSSystemExtensionManager.shared.submitRequest(request)
        }
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in
            guard activationRequest?.request === request else { return }
            onLog?("请在系统设置中允许 Hy2UI 网络扩展。")
        }
    }
    nonisolated func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties, withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction { .replace }
    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        Task { @MainActor in
            guard let active = activationRequest, active.request === request else { return }
            activationRequest = nil
            activation.complete(id: active.id, result: .failure(error))
        }
    }
    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        Task { @MainActor in
            guard let active = activationRequest, active.request === request else { return }
            if result == .willCompleteAfterReboot {
                activation.complete(id: active.id, result: .failure(ConfigurationError.invalid("系统扩展将在重启后完成启用。")))
            } else { activation.complete(id: active.id, result: .success(())) }
            activationRequest = nil
        }
    }
}
