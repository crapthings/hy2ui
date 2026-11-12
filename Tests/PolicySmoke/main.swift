import Foundation

/// Exercises service and policy transitions entirely through in-memory networking and persistence doubles.
@main
private struct PolicySmoke {
    @MainActor static func main() async throws {
        let suite = "hy2ui.policy-smoke." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        var legacyRouting = RoutingConfiguration()
        legacyRouting.directProcesses = ["LegacyProcess"]
        legacyRouting.finalAction = .direct
        let legacyData = try JSONEncoder().encode(legacyRouting)
        preferences.set(legacyData, forKey: "routingConfiguration")
        let migrated = RoutingPreferences(defaults: preferences)
        try require(migrated.configuration.directProcesses == ["LegacyProcess"] && migrated.configuration.finalAction == .direct,
                    "loading discarded saved routing choices")
        var rejected = false
        do { try migrated.configuration.validateCapture(systemProxy: true, enhanced: false, backend: .localTun) }
        catch { rejected = true }
        try require(rejected, "unsupported process routing was accepted for capture")
        try require(preferences.data(forKey: "routingConfiguration") == legacyData,
                    "loading migrated routing overwrote the original record")
        // The remaining service tests start with a supported, independent routing configuration.
        preferences.removeObject(forKey: "routingConfiguration")
        let repository = PolicyRepository()
        var first = Profile(); first.host = "first.example.com"; first.name = "JP1"
        var second = Profile(); second.host = "second.example.com"; second.name = "JP2"
        // A legacy per-server capture preference must not override the device-wide choice.
        second.systemProxyEnabled = false; second.enhancedModeEnabled = true
        try repository.save(first, credentials: Credentials(password: "first"))
        try repository.save(second, credentials: Credentials(password: "second"))
        let worker = PolicyWorker()
        let proxy = PolicyProxy()
        let connection = ConnectionCoordinator(worker: worker, proxy: proxy, vpn: PolicyVPN())
        let session = ApplicationSession(editor: ProfileEditor(repository: repository), connection: connection)
        let installer = HelperInstallationManager(dependencies: HelperInstallationDependencies(
            snapshot: { _ in throw PolicyFailure.failed("Installer must never run") },
            status: { _ in .notInstalled },
            authorize: { _ in throw PolicyFailure.failed("Authorization must never run") }
        ))
        let model = AppModel(makeSession: { session }, preferences: preferences, helperInstaller: installer)
        await model.initialize()
        try require(model.state == .idle && !model.automaticCaptureEnabled,
                    "legacy capture settings unexpectedly opted into automatic startup")
        try require(model.selectServer(second.id), "opening server editor failed")
        try require(model.defaultServer?.id == first.id, "editing replaced the default policy")
        model.profile.name = "Edited JP2"
        model.save()
        try require(model.defaultServer?.id == first.id, "saving replaced the default policy")
        await model.connect()
        try require(model.state == .connected && worker.passwords == ["first"], "service started the edited server")
        await model.useServer(second.id)
        try require(model.state == .connected && model.defaultServer?.id == second.id, "running switch failed")
        try require(worker.passwords == ["first", "second"], "switch mixed server credentials")
        try require(model.defaultServer?.systemProxyEnabled == true && model.defaultServer?.enhancedModeEnabled == false,
                    "legacy server preferences replaced global capture")
        worker.failPassword = "first"
        await model.useServer(first.id)
        try require(model.state == .connected && model.defaultServer?.id == second.id, "failed switch did not restore the original outbound")
        try require(model.policyNotice != nil, "failed switch hid its result")
        worker.failPassword = "first"
        proxy.failRestore = true
        let starts = worker.passwords.count
        await model.useServer(first.id)
        try require(model.state == .recoveryRequired && worker.passwords.count == starts, "switch continued after failed cleanup")
        proxy.failRestore = false
        await model.disconnect()
        try require(model.state == .idle, "retry did not finish cleanup")
        await model.useServer(first.id)
        try require(model.defaultServer?.id == first.id && model.state == .idle, "offline selection unexpectedly started service")
        worker.failPassword = nil
        await model.setCapture(enhanced: false, enabled: true)
        try require(model.state == .connected, "enabling capture did not start service")
        await model.setCapture(enhanced: false, enabled: false)
        try require(model.state == .idle && !proxy.needsRecovery, "disabling the last capture did not stop service")
        try require(model.defaultServer?.systemProxyEnabled == false, "capture settings were not updated")
        await model.useServer(second.id)
        try require(model.defaultServer?.id == second.id && model.state == .idle, "disabled capture blocked offline policy selection")
        model.profile.name = "Saved while stopped"
        model.save()
        try require(repository.library.selected?.name == "Saved while stopped", "server editing required active capture")
        let reloadedSession = ApplicationSession(editor: ProfileEditor(repository: repository),
            connection: ConnectionCoordinator(worker: PolicyWorker(), proxy: PolicyProxy(), vpn: PolicyVPN()))
        let reloaded = AppModel(makeSession: { reloadedSession }, preferences: preferences, helperInstaller: installer)
        await reloaded.initialize()
        try require(reloaded.defaultServer?.id == second.id && reloaded.defaultServer?.systemProxyEnabled == false,
                    "relaunch lost default policy or global capture settings")
        try require(reloaded.selectServer(first.id), "opening another server after reload failed")
        reloaded.profile.host = ""
        await reloaded.setCapture(enhanced: false, enabled: true)
        try require(reloaded.state == .connected && reloaded.defaultServer?.id == second.id,
                    "an unrelated invalid editor draft prevented the default policy from starting")
        await reloaded.disconnect()
        let automaticWorker = PolicyWorker()
        let automaticSession = ApplicationSession(editor: ProfileEditor(repository: repository),
            connection: ConnectionCoordinator(worker: automaticWorker, proxy: PolicyProxy(), vpn: PolicyVPN()))
        let automatic = AppModel(makeSession: { automaticSession }, preferences: preferences, helperInstaller: installer)
        await automatic.initialize()
        try require(automatic.state == .connected && automatic.systemProxyCaptureEnabled,
                    "an enabled capture switch was not restored on launch")
        try require(automatic.defaultServer?.id == second.id && automaticWorker.passwords == ["second"],
                    "automatic startup ignored the persisted FINAL policy")
        await automatic.disconnect()
        let failedWorker = PolicyWorker()
        failedWorker.failPassword = "second"
        let failedSession = ApplicationSession(editor: ProfileEditor(repository: repository),
            connection: ConnectionCoordinator(worker: failedWorker, proxy: PolicyProxy(), vpn: PolicyVPN()))
        let failed = AppModel(makeSession: { failedSession }, preferences: preferences, helperInstaller: installer)
        await failed.initialize()
        try require(failed.state == .idle && failed.systemProxyCaptureEnabled && failed.errorMessage != nil,
                    "startup failure lost the saved switch state or hid the error")
        await failed.setCapture(enhanced: false, enabled: false)
        let stoppedSession = ApplicationSession(editor: ProfileEditor(repository: repository),
            connection: ConnectionCoordinator(worker: PolicyWorker(), proxy: PolicyProxy(), vpn: PolicyVPN()))
        let stopped = AppModel(makeSession: { stoppedSession }, preferences: preferences, helperInstaller: installer)
        await stopped.initialize()
        try require(stopped.state == .idle && !stopped.automaticCaptureEnabled,
                    "a disabled capture switch unexpectedly restarted on launch")
        await stopped.setCapture(enhanced: true, enabled: true)
        try require(stopped.enhancedCaptureEnabled && !stopped.systemProxyCaptureEnabled
                    && stopped.requiresHelperInstallation && stopped.state == .idle,
                    "an enabled TUN switch did not wait for explicit helper installation")
        await stopped.useServer(second.id)
        try require(!stopped.isFinalDirect && stopped.state == .idle,
                    "waiting for helper installation prevented saving a server policy")
        let readyInstaller = HelperInstallationManager(dependencies: HelperInstallationDependencies(
            snapshot: { _ in throw PolicyFailure.failed("Installer must never run") },
            status: { _ in .current },
            authorize: { _ in throw PolicyFailure.failed("Authorization must never run") }
        ))
        let localTunnel = PolicyVPN()
        localTunnel.allowStart = true
        let tunSession = ApplicationSession(editor: ProfileEditor(repository: repository),
            connection: ConnectionCoordinator(worker: PolicyWorker(), proxy: PolicyProxy(), vpn: PolicyVPN(), localTunnel: localTunnel))
        let tunModel = AppModel(makeSession: { tunSession }, preferences: preferences, helperInstaller: readyInstaller)
        await tunModel.initialize()
        try require(tunModel.enhancedModeActive && localTunnel.starts == 1 && tunModel.state == .connected,
                    "a remembered TUN switch did not automatically start the available tunnel")
        await tunModel.setCapture(enhanced: true, enabled: false)
        try require(tunModel.state == .idle && !tunModel.automaticCaptureEnabled,
                    "turning TUN off did not stop and clear automatic activation")
        print("FINAL selection, policy rollback, cleanup recovery, saved capture switches and automatic proxy/TUN startup passed with simulated services only.")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw PolicyFailure.failed(message) }
    }
}

/// Stores server metadata and credentials in memory while preserving an explicitly chosen default policy.
@MainActor private final class PolicyRepository: ProfilePersisting {
    var library = ServerLibrary()
    var secrets: [UUID: Credentials] = [:]
    func load() throws -> ServerLibrary { library }
    func save(_ profile: Profile, credentials: Credentials) throws {
        library.upsert(profile, selecting: false)
        secrets[profile.id] = credentials
    }
    func select(_ id: UUID) throws { try library.select(id) }
    func remove(_ id: UUID) throws { library.remove(id); secrets.removeValue(forKey: id) }
    func credentials(for profile: Profile) throws -> Credentials { secrets[profile.id] ?? Credentials() }
}

/// Simulates proxy startup failures and records which credentials each service attempt received.
@MainActor private final class PolicyWorker: ProxyWorkerControlling {
    var onExit: (() -> Void)?
    var onLog: ((String) -> Void)?
    var isRunning = false
    var passwords: [String] = []
    var failPassword: String?
    var failLazyStartup = false
    func start(configuration: Data, credentials: Credentials) async throws {
        passwords.append(credentials.password)
        let lazy = try DesktopCoreConfiguration.object(configuration)["lazy"] as? Bool == true
        if (lazy && failLazyStartup) || (!lazy && credentials.password == failPassword) {
            throw PolicyFailure.failed("Simulated startup failure")
        }
        isRunning = true
    }
    func stop() async { isRunning = false }
}

/// Simulates proxy ownership and failed restoration without accessing the host's network configuration.
@MainActor private final class PolicyProxy: SystemProxyControlling {
    var needsRecovery = false
    var failRestore = false
    func enable(httpPort: Int, socksPort: Int, routing: RoutingConfiguration) async throws { needsRecovery = true }
    func restore() throws {
        if failRestore { throw PolicyFailure.failed("Simulated cleanup failure") }
        needsRecovery = false
    }
}

/// Simulates tunnel status callbacks only when explicitly enabled and never creates a real network interface.
@MainActor private final class PolicyVPN: VPNConnectionControlling {
    var onStatus: ((VPNConnectionStatus) -> Void)?
    var onLog: ((String) -> Void)?
    var allowStart = false
    var starts = 0
    func load() async throws {}
    func start(profile: Profile, configuration: Data) async throws {
        guard allowStart else { throw PolicyFailure.failed("Unexpected simulated VPN start") }
        starts += 1
        onStatus?(.connected)
    }
    func stop() async throws {}
    func cancelPendingActivation() {}
}

/// Reports a simulated failure or a violated policy lifecycle invariant.
private enum PolicyFailure: Error { case failed(String) }
