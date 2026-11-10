import Foundation
import Testing
@testable import Hy2Connection
import Hy2Models

/// Provides deterministic suspension points for lifecycle tests without timing-based sleeps.
@MainActor
private final class TestGate {
    private var entered = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters = []
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }
    func release() {
        released = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

/// Records worker resource acquisition and cleanup without launching a process.
@MainActor
private final class FakeWorker: ProxyWorkerControlling {
    var onExit: (() -> Void)?
    var onLog: ((String) -> Void)?
    var isRunning = false
    var starts = 0
    var configuration: Data?
    var exitsBeforeStartReturns = false
    var stops = 0
    var onStart: (() -> Void)?
    var startGate: TestGate?
    var stopGate: TestGate?

    func start(configuration: Data, credentials: Credentials) async throws {
        starts += 1
        self.configuration = configuration
        onStart?()
        isRunning = true
        await startGate?.suspend()
        try Task.checkCancellation()
        if exitsBeforeStartReturns { isRunning = false }
    }
    func stop() async {
        stops += 1
        await stopGate?.suspend()
        isRunning = false
    }
}

/// Models journal ownership and restoration failure without touching system preferences.
@MainActor
private final class FakeProxy: SystemProxyControlling, PACProxyControlling {
    var pacGate: TestGate?
    var pacEnables = 0
    var pacConfiguration: RoutingConfiguration?

    func enablePAC(configuration: RoutingConfiguration, httpPort: Int) async throws {
        pacEnables += 1; pacConfiguration = configuration
        await pacGate?.suspend()
        try Task.checkCancellation()
        needsRecovery = true
    }
    var needsRecovery = false
    var enables = 0
    var restores = 0
    var restoreFails = false
    var onEnable: (() -> Void)?

    func enable(httpPort: Int, socksPort: Int) throws {
        enables += 1
        onEnable?()
        needsRecovery = true
    }
    func restore() throws {
        restores += 1
        if restoreFails { throw ConfigurationError.invalid("restore failed") }
        needsRecovery = false
    }
}

/// Models VPN requests and cancellation signals without loading a network extension.
@MainActor
private final class FakeVPN: VPNConnectionControlling {
    var onStatus: ((VPNConnectionStatus) -> Void)?
    var onLog: ((String) -> Void)?
    var cancellations = 0
    var starts = 0
    var configuration: Data?
    var stops = 0
    var startStatus = VPNConnectionStatus.connected
    var startFails = false
    var stopFails = false
    var onStart: (() -> Void)?
    var onCancellation: (() -> Void)?
    func load() async throws {}
    func start(profile: Profile, configuration: Data) async throws {
        starts += 1
        self.configuration = configuration
        onStart?()
        if startFails { throw ConfigurationError.invalid("tunnel start failed") }
        onStatus?(startStatus)
    }
    func stop() async throws {
        stops += 1
        if stopFails { throw ConfigurationError.invalid("tunnel cleanup failed") }
        onStatus?(.disconnected)
    }
    func cancelPendingActivation() {
        cancellations += 1
        onCancellation?()
    }
}

/// Supplies profile or credential failures while remaining available for explicit user repairs.
@MainActor
private final class FakeRepository: ProfilePersisting {
    var loadFails = false
    var credentialsFail = false
    var onLoad: (() -> Void)?
    var saves = 0
    func select(_ id: UUID) throws {}
    func remove(_ id: UUID) throws {}
    func load() throws -> ServerLibrary {
        onLoad?()
        if loadFails { throw ConfigurationError.invalid("profile unreadable") }
        var profile = Profile()
        profile.host = "example.com"
        return try ServerLibrary(profiles: [profile], selectedID: profile.id)
    }
    func credentials(for profile: Profile) throws -> Credentials {
        if credentialsFail { throw ConfigurationError.invalid("keychain unavailable") }
        return Credentials(password: "test")
    }
    func save(_ profile: Profile, credentials: Credentials) throws { saves += 1 }
}

/// Verifies recovery remains reachable when either profile decoding or credential loading fails.
@Test @MainActor
func recoverySurvivesProfileAndKeychainFailures() async throws {
    for keychainFailure in [false, true] {
        let repository = FakeRepository()
        repository.loadFails = !keychainFailure
        repository.credentialsFail = keychainFailure
        let worker = FakeWorker()
        let proxy = FakeProxy()
        proxy.needsRecovery = true
        let coordinator = ConnectionCoordinator(worker: worker, proxy: proxy, vpn: FakeVPN())
        repository.onLoad = { #expect(coordinator.state == .recoveryRequired) }
        let editor = ProfileEditor(repository: repository)
        let session = ApplicationSession(editor: editor, connection: coordinator)
        await session.initialize()
        #expect(session.initialized)
        #expect(editor.notice != nil)
        #expect(coordinator.needsProxyRecovery)
        await coordinator.recoverProxy()
        #expect(!coordinator.needsProxyRecovery)
        editor.profile.host = "example.com"
        try editor.save()
        #expect(repository.saves == 1)
    }
}

/// Verifies a failed restoration retains the worker and prevents editing until a successful retry.
@Test @MainActor
func failedRestoreRetainsResourcesUntilRetry() async {
    let worker = FakeWorker()
    let proxy = FakeProxy()
    let coordinator = ConnectionCoordinator(worker: worker, proxy: proxy, vpn: FakeVPN())
    await coordinator.connect(profile: Profile(), configuration: Data(), credentials: Credentials())
    #expect(coordinator.state == .connected)
    proxy.restoreFails = true
    await coordinator.disconnect()
    #expect(coordinator.state == .recoveryRequired)
    #expect(coordinator.hasOwnedResources)
    #expect(coordinator.editingDisabled)
    #expect(!coordinator.canConnect)
    #expect(worker.stops == 0)
    proxy.restoreFails = false
    await coordinator.recoverProxy()
    #expect(coordinator.state == .idle)
    #expect(!coordinator.hasOwnedResources)
    #expect(worker.stops == 1)
}

/// Verifies an already-cancelled caller cannot acquire a worker or proxy settings.
@Test @MainActor
func cancelledCallerDoesNotStartResources() async {
    let worker = FakeWorker()
    let proxy = FakeProxy()
    let coordinator = ConnectionCoordinator(worker: worker, proxy: proxy, vpn: FakeVPN())
    let task = Task { await coordinator.connect(profile: Profile(), configuration: Data(), credentials: Credentials()) }
    task.cancel()
    await task.value
    #expect(worker.starts == 0)
    #expect(proxy.enables == 0)
    #expect(coordinator.state == .idle)
}

/// Verifies cancellation during worker startup completes rollback before any proxy is enabled.
@Test @MainActor
func cancellationDuringStartupNeverEnablesProxy() async {
    let gate = TestGate()
    let worker = FakeWorker()
    worker.startGate = gate
    let proxy = FakeProxy()
    let vpn = FakeVPN()
    let coordinator = ConnectionCoordinator(worker: worker, proxy: proxy, vpn: vpn)
    let connect = Task { await coordinator.connect(profile: Profile(), configuration: Data(), credentials: Credentials()) }
    await gate.waitUntilEntered()
    let cancelled = TestGate()
    vpn.onCancellation = { cancelled.release() }
    let stop = Task { await coordinator.disconnect() }
    await cancelled.suspend()
    gate.release()
    await connect.value
    await stop.value
    #expect(proxy.enables == 0)
    #expect(worker.stops == 1)
    #expect(coordinator.state == .idle)
}

/// Verifies concurrent disconnect callers share one cleanup operation.
@Test @MainActor
func concurrentDisconnectsCleanResourcesOnce() async {
    let worker = FakeWorker()
    let stopGate = TestGate()
    worker.stopGate = stopGate
    let proxy = FakeProxy()
    let coordinator = ConnectionCoordinator(worker: worker, proxy: proxy, vpn: FakeVPN())
    await coordinator.connect(profile: Profile(), configuration: Data(), credentials: Credentials())
    let first = Task { await coordinator.disconnect() }
    await stopGate.waitUntilEntered()
    let second = Task { await coordinator.disconnect() }
    stopGate.release()
    await first.value
    await second.value
    #expect(proxy.restores == 1)
    #expect(worker.stops == 1)
    #expect(coordinator.state == .idle)
}

/// Rejects buffered readiness when a worker has exited before the coordinator can install proxies.
@Test @MainActor
func exitedWorkerCannotEnableProxyAfterReadiness() async {
    let worker = FakeWorker()
    worker.exitsBeforeStartReturns = true
    let proxy = FakeProxy()
    let coordinator = ConnectionCoordinator(worker: worker, proxy: proxy, vpn: FakeVPN())
    await coordinator.connect(profile: Profile(), configuration: Data(), credentials: Credentials())
    #expect(proxy.enables == 0)
    #expect(worker.stops == 1)
    #expect(!coordinator.hasOwnedResources)
    #expect(coordinator.state == .idle)
    #expect(coordinator.lastError != nil)
}

/// Starts proxy listeners and settings before the independently selected local tunnel.
@Test @MainActor
func combinedCaptureStartsBothServicesInOrder() async {
    let worker = FakeWorker()
    let proxy = FakeProxy()
    let local = FakeVPN()
    let networkExtension = FakeVPN()
    var order: [String] = []
    worker.onStart = { order.append("worker") }
    proxy.onEnable = { order.append("proxy") }
    local.onStart = { order.append("tun") }
    var profile = Profile()
    profile.enhancedModeEnabled = true
    let coordinator = ConnectionCoordinator(worker: worker, proxy: proxy, vpn: networkExtension, localTunnel: local)
    await coordinator.connect(profile: profile, configuration: Data(), credentials: Credentials())
    #expect(order == ["worker", "proxy", "tun"])
    #expect(coordinator.systemProxyActive)
    #expect(coordinator.enhancedModeActive)
    #expect(networkExtension.starts == 0)
    await coordinator.disconnect()
    #expect(worker.stops == 1)
    #expect(local.stops == 1)
    #expect(coordinator.state == .idle)
}

/// Runs local enhanced mode without opening any local HTTP or SOCKS worker.
@Test @MainActor
func enhancedOnlyDoesNotStartSystemProxy() async {
    let worker = FakeWorker()
    let proxy = FakeProxy()
    let local = FakeVPN()
    var profile = Profile()
    profile.systemProxyEnabled = false
    profile.enhancedModeEnabled = true
    let coordinator = ConnectionCoordinator(worker: worker, proxy: proxy, vpn: FakeVPN(), localTunnel: local)
    await coordinator.connect(profile: profile, configuration: Data(), credentials: Credentials())
    #expect(local.starts == 1)
    #expect(worker.starts == 0)
    #expect(proxy.enables == 0)
    #expect(coordinator.enhancedModeActive)
    #expect(!coordinator.systemProxyActive)
    await coordinator.disconnect()
}

/// Retains Network Extension as an explicit enhanced-mode backend instead of the self-use default.
@Test @MainActor
func explicitNetworkExtensionBackendUsesItsOwnService() async {
    let extensionService = FakeVPN()
    let local = FakeVPN()
    var profile = Profile()
    profile.systemProxyEnabled = false
    profile.enhancedModeEnabled = true
    profile.enhancedBackend = .networkExtension
    let coordinator = ConnectionCoordinator(worker: FakeWorker(), proxy: FakeProxy(), vpn: extensionService, localTunnel: local)
    await coordinator.connect(profile: profile, configuration: Data(), credentials: Credentials())
    #expect(extensionService.starts == 1)
    #expect(local.starts == 0)
    await coordinator.disconnect()
}

/// Rolls back an already-installed system proxy if enhanced-mode startup fails.
@Test @MainActor
func failedTunnelStartRollsBackBothResources() async {
    let worker = FakeWorker()
    let proxy = FakeProxy()
    let local = FakeVPN()
    local.startFails = true
    var profile = Profile()
    profile.enhancedModeEnabled = true
    let coordinator = ConnectionCoordinator(worker: worker, proxy: proxy, vpn: FakeVPN(), localTunnel: local)
    await coordinator.connect(profile: profile, configuration: Data(), credentials: Credentials())
    #expect(proxy.enables == 1)
    #expect(!proxy.needsRecovery)
    #expect(worker.stops == 1)
    #expect(local.stops == 1)
    #expect(!coordinator.hasOwnedResources)
    #expect(coordinator.lastError == "tunnel start failed")
}

/// Stops the independent tunnel even when restoring system proxy settings requires a retry.
@Test @MainActor
func failedProxyRestoreStillCleansTunnel() async {
    let worker = FakeWorker()
    let proxy = FakeProxy()
    let local = FakeVPN()
    var profile = Profile()
    profile.enhancedModeEnabled = true
    let coordinator = ConnectionCoordinator(worker: worker, proxy: proxy, vpn: FakeVPN(), localTunnel: local)
    await coordinator.connect(profile: profile, configuration: Data(), credentials: Credentials())
    proxy.restoreFails = true
    await coordinator.disconnect()
    #expect(local.stops == 1)
    #expect(worker.stops == 0)
    #expect(coordinator.systemProxyActive)
    #expect(!coordinator.enhancedModeActive)
    #expect(coordinator.state == .recoveryRequired)
    proxy.restoreFails = false
    await coordinator.recoverProxy()
    #expect(worker.stops == 1)
    #expect(!coordinator.hasOwnedResources)
}

/// Keeps failed tunnel cleanup owned until its independent stop can succeed on retry.
@Test @MainActor
func failedTunnelCleanupRetainsOwnershipWithoutKeepingProxy() async {
    let worker = FakeWorker()
    let proxy = FakeProxy()
    let local = FakeVPN()
    var profile = Profile()
    profile.enhancedModeEnabled = true
    let coordinator = ConnectionCoordinator(worker: worker, proxy: proxy, vpn: FakeVPN(), localTunnel: local)
    await coordinator.connect(profile: profile, configuration: Data(), credentials: Credentials())
    local.stopFails = true
    await coordinator.disconnect()
    #expect(worker.stops == 1)
    #expect(!proxy.needsRecovery)
    #expect(coordinator.hasOwnedResources)
    #expect(coordinator.editingDisabled)
    local.stopFails = false
    await coordinator.disconnect()
    #expect(!coordinator.hasOwnedResources)
    #expect(coordinator.state == .idle)
}

/// Shares one frozen server endpoint between proxy and tunnel to keep its route exclusion consistent.
@Test @MainActor
func combinedCaptureSharesOneResolvedConfiguration() async {
    let worker = FakeWorker()
    let local = FakeVPN()
    var profile = Profile()
    profile.enhancedModeEnabled = true
    let frozen = Data("same-numeric-endpoint".utf8)
    let coordinator = ConnectionCoordinator(worker: worker, proxy: FakeProxy(), vpn: FakeVPN(), localTunnel: local,
        resolveProxyConfiguration: { _ in frozen })
    await coordinator.connect(profile: profile, configuration: Data("original-domain".utf8), credentials: Credentials())
    #expect(worker.configuration == frozen)
    #expect(local.configuration == frozen)
    await coordinator.disconnect()
}

/// Completes cancellation while a background endpoint resolver is still waiting for its own result.
@Test @MainActor
func cancellationDoesNotWaitForCombinedEndpointResolution() async {
    let gate = TestGate()
    let worker = FakeWorker()
    let local = FakeVPN()
    var profile = Profile()
    profile.enhancedModeEnabled = true
    let coordinator = ConnectionCoordinator(worker: worker, proxy: FakeProxy(), vpn: FakeVPN(), localTunnel: local,
        resolveProxyConfiguration: { configuration in await gate.suspend(); return configuration })
    let connecting = Task { await coordinator.connect(profile: profile, configuration: Data(), credentials: Credentials()) }
    await gate.waitUntilEntered()
    await coordinator.disconnect()
    #expect(coordinator.state == .idle)
    #expect(worker.starts == 0)
    #expect(local.starts == 0)
    gate.release()
    await connecting.value
}

/// Keeps interrupted tunnel ownership visible until cleanup succeeds without claiming a reconnect is running.
@Test @MainActor
func interruptedLocalTunnelRequiresAcknowledgedCleanup() async {
    let local = FakeVPN()
    let coordinator = ConnectionCoordinator(worker: FakeWorker(), proxy: FakeProxy(), vpn: FakeVPN(), localTunnel: local)
    var profile = Profile()
    profile.systemProxyEnabled = false
    profile.enhancedModeEnabled = true
    await coordinator.connect(profile: profile, configuration: Data(), credentials: Credentials())
    local.onStatus?(.recoveryRequired)
    #expect(coordinator.state == .recoveryRequired)
    #expect(!coordinator.enhancedModeActive && coordinator.hasOwnedResources)
    #expect(coordinator.editingDisabled && !coordinator.canConnect)
    #expect(coordinator.lastError != nil)
    local.stopFails = true
    await coordinator.disconnect()
    #expect(coordinator.state == .recoveryRequired && coordinator.hasOwnedResources)
    local.stopFails = false
    await coordinator.disconnect()
    #expect(coordinator.state == .idle && !coordinator.hasOwnedResources)
}

/// Preserves a recovery notice that arrives while a tunnel start call is still returning.
@Test @MainActor
func startupReturnDoesNotOverwriteInterruptedTunnelNotice() async {
    let local = FakeVPN()
    let coordinator = ConnectionCoordinator(worker: FakeWorker(), proxy: FakeProxy(), vpn: FakeVPN(), localTunnel: local)
    local.startStatus = .recoveryRequired
    var profile = Profile()
    profile.systemProxyEnabled = false
    profile.enhancedModeEnabled = true
    await coordinator.connect(profile: profile, configuration: Data(), credentials: Credentials())
    #expect(coordinator.state == .recoveryRequired)
    #expect(coordinator.hasOwnedResources)
    #expect(coordinator.message == coordinator.lastError)
    await coordinator.disconnect()
    #expect(coordinator.state == .idle && !coordinator.hasOwnedResources)
}

/// Clears a tunnel interruption only when a real core connection-success event is observed.
@Test @MainActor func observedTunnelReconnectClearsStaleFailure() async {
    let local = FakeVPN()
    let coordinator = ConnectionCoordinator(worker: FakeWorker(), proxy: FakeProxy(), vpn: FakeVPN(), localTunnel: local)
    var profile = Profile()
    profile.systemProxyEnabled = false
    profile.enhancedModeEnabled = true
    await coordinator.connect(profile: profile, configuration: Data(), credentials: Credentials())
    local.onStatus?(.recoveryRequired)
    #expect(coordinator.lastError != nil)
    local.onStatus?(.connected)
    #expect(coordinator.state == .connected && coordinator.lastError == nil)
    #expect(coordinator.enhancedModeActive && coordinator.hasOwnedResources)
    await coordinator.disconnect()
}


/// Verifies PAC startup and disconnect share the existing proxy recovery lifecycle.
@Test @MainActor func automaticProxyLifecycle() async {
    let worker = FakeWorker(); let proxy = FakeProxy()
    let coordinator = ConnectionCoordinator(worker: worker, proxy: proxy, vpn: FakeVPN())
    var profile = Profile(); profile.systemProxyEnabled = true; profile.enhancedModeEnabled = false
    var routing = RoutingConfiguration(); routing.mode = .generatedPAC
    await coordinator.connect(profile: profile, configuration: Data(), credentials: Credentials(), routing: routing)
    #expect(coordinator.state == .connected)
    #expect(proxy.pacEnables == 1 && proxy.enables == 0)
    #expect(proxy.pacConfiguration == routing)
    await coordinator.disconnect()
    #expect(!proxy.needsRecovery && worker.stops == 1)
}

/// Verifies cancellation while PAC starts restores resources before another attempt can connect.
@Test @MainActor func automaticProxyCancellation() async {
    let worker = FakeWorker(); let proxy = FakeProxy(); let gate = TestGate(); proxy.pacGate = gate
    let coordinator = ConnectionCoordinator(worker: worker, proxy: proxy, vpn: FakeVPN())
    var profile = Profile(); profile.systemProxyEnabled = true; profile.enhancedModeEnabled = false
    var routing = RoutingConfiguration(); routing.mode = .generatedPAC
    let attempt = Task { await coordinator.connect(profile: profile, configuration: Data(), credentials: Credentials(), routing: routing) }
    await gate.waitUntilEntered()
    let disconnect = Task { await coordinator.disconnect() }
    while coordinator.state != .stopping { await Task.yield() }
    gate.release()
    await attempt.value; await disconnect.value
    #expect(coordinator.state == .idle)
    #expect(!proxy.needsRecovery && worker.stops == 1 && proxy.restores > 0)
}
