import Foundation
import Observation
#if SWIFT_PACKAGE
import Hy2Models
#endif

/// Serializes independent proxy and enhanced-mode resources until their cleanup has succeeded.
@MainActor @Observable
public final class ConnectionCoordinator {
    public private(set) var state = ConnectionState.idle
    public private(set) var message = "添加服务器，选择流量接管方式。"
    public private(set) var lastError: String?
    public var onTelemetry: ((CoreTelemetrySource, CoreTelemetryObservation) -> Void)?
    public var onLog: ((String) -> Void)?
    private let worker: any ProxyWorkerControlling
    private let proxy: any SystemProxyControlling
    private let vpn: any VPNConnectionControlling
    private let localTunnel: (any VPNConnectionControlling)?
    private let resolveProxyConfiguration: @Sendable (Data) async throws -> Data
    private var workerOwned = false
    private var tunnelOwned = false
    private var tunnelStartPending = false
    private var tunnelState = ConnectionState.connecting
    private var selectedBackend: EnhancedBackend?
    private var connectionTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var attempt = UUID()

    public var needsProxyRecovery: Bool { proxy.needsRecovery }
    public var systemProxyActive: Bool { workerOwned && needsProxyRecovery }
    public var enhancedModeActive: Bool { tunnelOwned && tunnelState == .connected }
    public var hasOwnedResources: Bool { workerOwned || tunnelOwned || needsProxyRecovery }
    public var editingDisabled: Bool { state != .idle || hasOwnedResources }
    public var canConnect: Bool { state == .idle && !hasOwnedResources && connectionTask == nil && stopTask == nil }
    private var tunnel: (any VPNConnectionControlling)? {
        selectedBackend == .localTun ? localTunnel : vpn
    }

    public init(worker: any ProxyWorkerControlling, proxy: any SystemProxyControlling, vpn: any VPNConnectionControlling,
                localTunnel: (any VPNConnectionControlling)? = nil,
                resolveProxyConfiguration: @escaping @Sendable (Data) async throws -> Data = { $0 }) {
        self.worker = worker
        self.proxy = proxy
        self.vpn = vpn
        self.localTunnel = localTunnel
        self.resolveProxyConfiguration = resolveProxyConfiguration
        worker.onLog = { [weak self] in self?.onLog?($0) }
        worker.onExit = { [weak self] in self?.workerExited() }
        vpn.onLog = { [weak self] in self?.onLog?($0) }
        vpn.onStatus = { [weak self] in self?.tunnelStatus($0, backend: .networkExtension) }
        localTunnel?.onLog = { [weak self] in self?.onLog?($0) }
        localTunnel?.onStatus = { [weak self] in self?.tunnelStatus($0, backend: .localTun) }
        (worker as? any CoreTelemetryProviding)?.onTelemetry = { [weak self] in self?.onTelemetry?(.proxy, $0) }
        (localTunnel as? any CoreTelemetryProviding)?.onTelemetry = { [weak self] in self?.onTelemetry?(.localTun, $0) }
        refreshRecovery()
    }

    public func refreshRecovery() {
        if needsProxyRecovery, state == .idle {
            state = .recoveryRequired
            message = "发现待恢复的系统代理，请先恢复设置。"
        }
    }

    public func loadExistingVPN() async {
        do { try await vpn.load() }
        catch { onLog?("系统扩展状态尚未加载：\(error.localizedDescription)") }
        do { try await localTunnel?.load() }
        catch { onLog?("本地增强模式尚未就绪：\(error.localizedDescription)") }
    }

    public func connect(profile: Profile, configuration: Data, credentials: Credentials, routing: RoutingConfiguration = RoutingConfiguration()) async {
        guard !Task.isCancelled, canConnect else { return }
        guard profile.systemProxyEnabled || profile.enhancedModeEnabled else {
            report(ConfigurationError.invalid("请至少启用系统代理或增强模式。")); return
        }
        do { try routing.validateCapture(systemProxy: profile.systemProxyEnabled, enhanced: profile.enhancedModeEnabled, backend: profile.enhancedBackend) }
        catch { report(error); return }
        state = .connecting
        selectedBackend = profile.enhancedModeEnabled ? profile.enhancedBackend : nil
        lastError = nil
        message = "正在连接 \(profile.serverAddress)…"
        let token = UUID()
        attempt = token
        let task = Task { await self.start(profile: profile, configuration: configuration, credentials: credentials, routing: routing, token: token) }
        connectionTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.attempt == token else { return }
                await self.disconnect()
            }
        }
        if attempt == token { connectionTask = nil }
    }

    public func disconnect() async { await stop(restoreOnly: false) }
    public func recoverProxy() async { await stop(restoreOnly: true) }

    private func stop(restoreOnly: Bool) async {
        if let stopTask { await stopTask.value; return }
        state = .stopping
        let pending = connectionTask
        let cancelStartup = !restoreOnly || !tunnelOwned
        if cancelStartup {
            pending?.cancel()
            vpn.cancelPendingActivation()
            localTunnel?.cancelPendingActivation()
        }
        let task = Task {
            if cancelStartup { await pending?.value }
            await self.cleanup(stopTunnel: !restoreOnly)
        }
        stopTask = task
        await task.value
        stopTask = nil
    }

    private func start(profile: Profile, configuration: Data, credentials: Credentials, routing: RoutingConfiguration, token: UUID) async {
        do {
            try Task.checkCancellation()
            guard attempt == token, state == .connecting else { throw CancellationError() }
            if profile.enhancedModeEnabled, tunnel == nil {
                throw ConfigurationError.invalid("本地增强模式服务未安装，请在增强模式设置中安装后台。")
            }
            let finalDirect = try DesktopCoreConfiguration.finalDirect(in: configuration)
            let resolvedConfiguration = profile.enhancedModeEnabled && !finalDirect
                ? try await StartupResolution().resolve(configuration, using: resolveProxyConfiguration) : configuration
            try Task.checkCancellation()
            if profile.systemProxyEnabled {
                workerOwned = true
                try await worker.start(configuration: DesktopCoreConfiguration.coreOnly(resolvedConfiguration), credentials: credentials)
                try ensureCurrentStartup(token)
                guard worker.isRunning else { throw ConfigurationError.invalid("Rust 客户端已停止，未启用系统代理。") }
                if routing.mode == .manual {
                    try await proxy.enable(httpPort: profile.httpPort, socksPort: profile.socksPort, routing: routing)
                    try ensureCurrentStartup(token)
                }
                else {
                    guard let automatic = proxy as? any PACProxyControlling else { throw ConfigurationError.invalid("当前系统代理后端不支持 PAC。") }
                    try await automatic.enablePAC(configuration: routing, httpPort: profile.httpPort)
                    try ensureCurrentStartup(token)
                }
            }
            if profile.enhancedModeEnabled {
                try await startTunnel(profile: profile, configuration: resolvedConfiguration, token: token)
            } else {
                state = .connected
                message = "系统代理已启用。"
            }
        } catch {
            tunnelStartPending = false
            guard state != .stopping else { return }
            let cancelled = Task.isCancelled || error is CancellationError
            state = .stopping
            let rollback = Task { await self.cleanup(stopTunnel: true) }
            stopTask = rollback
            await rollback.value
            stopTask = nil
            if hasOwnedResources { onLog?("启动失败：\(error.localizedDescription)"); return }
            if cancelled { message = "连接已取消。" }
            else { report(error) }
        }
    }

    private func startTunnel(profile: Profile, configuration: Data, token: UUID) async throws {
        guard let tunnel else { throw ConfigurationError.invalid("增强模式后台不可用。") }
        tunnelOwned = true
        tunnelState = .connecting
        tunnelStartPending = true
        defer { tunnelStartPending = false }
        try await tunnel.start(profile: profile, configuration: configuration)
        try ensureCurrentStartup(token)
        if tunnelState == .connected {
            state = .connected
            message = connectedMessage
        } else if tunnelState != .recoveryRequired {
            message = "增强模式正在建立连接…"
        }
    }

    private func ensureCurrentStartup(_ token: UUID) throws {
        try Task.checkCancellation()
        guard attempt == token, state != .stopping else { throw CancellationError() }
    }

    private func cleanup(stopTunnel: Bool) async {
        var errors: [String] = []
        do {
            // A worker must keep serving until its persistent proxy settings have been restored.
            try proxy.restore()
            if workerOwned { await worker.stop(); workerOwned = false }
        } catch { errors.append(error.localizedDescription) }
        // A proxy-restore failure must not prevent independently stopping a TUN and its DNS settings.
        if stopTunnel, tunnelOwned {
            do {
                try await tunnel?.stop()
                tunnelOwned = false
            } catch { errors.append(error.localizedDescription) }
        }
        if errors.isEmpty {
            state = tunnelOwned ? (tunnelState == .stopping ? .recoveryRequired : tunnelState) : .idle
            if !tunnelOwned { selectedBackend = nil }
            lastError = nil
            if tunnelOwned && tunnelState == .stopping {
                message = "系统代理已恢复，增强模式尚未确认断开，请重试清理。"
            } else {
                message = tunnelOwned ? "系统代理已恢复，增强模式会话保持运行。" : "已断开，网络设置已恢复。"
            }
        } else {
            state = .recoveryRequired
            report(ConfigurationError.invalid(errors.joined(separator: "；")))
        }
    }

    private var connectedMessage: String {
        systemProxyActive ? "系统代理与增强模式已启用。" : "增强模式已连接。"
    }

    private func workerExited() {
        guard workerOwned else { return }
        if state == .connecting { connectionTask?.cancel(); return }
        guard state == .connected else { return }
        Task {
            await disconnect()
            report(ConfigurationError.invalid("Rust 客户端意外退出，已尝试恢复网络设置。"))
        }
    }

    private func tunnelStatus(_ status: VPNConnectionStatus, backend: EnhancedBackend) {
        guard selectedBackend == nil || selectedBackend == backend else { return }
        switch status {
        case .recoveryRequired:
            selectedBackend = backend
            tunnelOwned = true
            tunnelState = .recoveryRequired
            guard state != .stopping else { return }
            state = .recoveryRequired
            report(ConfigurationError.invalid("增强模式连接中断，网络恢复尚未确认，请重试清理。"))
        case .connected, .connecting, .reasserting:
            selectedBackend = backend
            tunnelOwned = true
            tunnelState = status == .connected ? .connected : .connecting
            guard state != .stopping else { return }
            state = needsProxyRecovery && !workerOwned ? .recoveryRequired : tunnelState
            if status == .connected { lastError = nil }
            message = status == .connected ? connectedMessage : "增强模式正在连接…"
        case .disconnecting:
            guard tunnelOwned else { return }
            tunnelState = .stopping
            state = .stopping
        case .disconnected, .invalid:
            guard tunnelOwned, !tunnelStartPending else { return }
            tunnelOwned = false
            let expected = state == .stopping
            guard stopTask == nil else { return }
            if expected {
                state = needsProxyRecovery && !workerOwned ? .recoveryRequired : (workerOwned ? .connected : .idle)
                message = workerOwned ? "增强模式已断开，系统代理保持运行。" : "增强模式已断开。"
            } else {
                Task {
                    await disconnect()
                    report(ConfigurationError.invalid("增强模式已停止，请检查连接日志。"))
                }
            }
        }
    }

    private func report(_ error: Error) {
        lastError = error.localizedDescription
        message = error.localizedDescription
        onLog?(message)
    }
}
