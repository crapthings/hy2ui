import Foundation
import Observation
#if SWIFT_PACKAGE
import Hy2Models
import Hy2Connection
#endif

/// Presents editable configuration and connection state to the application's windows and menu bar.
@MainActor @Observable
final class AppModel {
    var language: AppLanguage = .preferred() {
        didSet { language.save() }
    }
    func localized(_ value: String) -> String { AppLocalization.text(value, language: language) }

    func localizedLog(_ value: String, detailed: Bool = true) -> String {
        guard let separator = value.range(of: "  ") else { return localized(value) }
        var body = String(value[separator.upperBound...])
        if !detailed, let metadata = body.range(of: " [code=") {
            body = String(body[..<metadata.lowerBound])
        }
        let rendered = CoreFlowDiagnostic.fromLogMessage(body).map { $0.render(detailed: detailed, localized: localized) } ?? localized(body)
        return String(value[..<separator.upperBound]) + rendered
    }

    private var session: ApplicationSession?
    private let preferences: UserDefaults
    private var serviceConfiguration: ServiceConfiguration?
    private var serviceConfigurationLoaded = false
    private(set) var isSwitchingServer = false
    private(set) var isUpdatingCapture = false
    private(set) var automaticCaptureEnabled: Bool
    private static let automaticCaptureKey = "automaticCaptureEnabled.v1"
    var enhancedCaptureEnabled: Bool { automaticCaptureEnabled && profile.enhancedModeEnabled }
    var systemProxyCaptureEnabled: Bool { automaticCaptureEnabled && profile.systemProxyEnabled }
    var canChangeCapture: Bool {
        initialized && defaultServer != nil && !isManagingHelper && !isSwitchingServer
            && (state == .idle || state == .connected || state == .connecting)
    }
    private(set) var policyNotice: String?
    private static let serviceConfigurationKey = "serviceConfiguration.v1"
    private let makeSession: @MainActor () throws -> ApplicationSession
    private var initializationStarted = false
    private var draft = Profile()
    private var draftCredentials = Credentials()
    private var initializationError: String?
    let helperInstaller: HelperInstallationManager
    let routing: RoutingPreferences
    let enhancedSetup: EnhancedModeOnboarding
    private(set) var isManagingHelper = false
    private var connectedRouting: RoutingConfiguration?
    var hasPendingRoutingChanges: Bool { state == .connected && connectedRouting?.activeRules != routing.configuration.activeRules }
    private(set) var logs: [String] = []

    var profile: Profile {
        get {
            let server = session?.editor.profile ?? draft
            return serviceConfiguration?.applying(to: server) ?? server
        }
        set {
            serviceConfiguration = ServiceConfiguration(profile: newValue)
            if let session { session.editor.profile = newValue }
            else { draft = newValue }
        }
    }
    var credentials: Credentials {
        get { session?.editor.credentials ?? draftCredentials }
        set {
            if let session { session.editor.credentials = newValue }
            else { draftCredentials = newValue }
        }
    }
    let serverList: ServerListPreferences
    var sortedServers: [Profile] { serverList.sorted(servers) }

    var servers: [Profile] { session?.editor.profiles ?? [] }
    var defaultServer: Profile? {
        guard let server = session?.editor.library.selected else { return nil }
        return serviceConfiguration?.applying(to: server) ?? server
    }
    var isFinalDirect: Bool { routing.configuration.finalAction == .direct }
    var finalPolicyTitle: String {
        if isFinalDirect { return "DIRECT" }
        if case let .group(id) = routing.configuration.finalOutbound,
           let group = routing.configuration.groups.first(where: { $0.id == id }) { return group.name }
        return defaultServer?.name ?? localized("请先添加策略")
    }
    var serviceTitle: String {
        if isUpdatingCapture { return "正在应用接管设置" }
        if isSwitchingServer { return "正在切换出口" }
        switch state {
        case .idle: return automaticCaptureEnabled ? (requiresHelperInstallation ? "需要安装增强模式" : "待启动") : "已关闭"
        case .connecting: return "正在启动"
        case .connected: return "运行中"
        case .stopping: return "正在停止"
        case .recoveryRequired: return "需要恢复"
        }
    }
    var canChooseServer: Bool {
        initialized && !isManagingHelper && !isSwitchingServer && (state == .idle || state == .connected)
    }
    var hasServer: Bool { session?.editor.hasServer == true }
    var hasUnsavedChanges: Bool { session?.editor.hasChanges == true }

    var state: ConnectionState { session?.connection.state ?? .idle }
    var errorMessage: String? {
        initializationError ?? (session?.editor.noticeIsError == true ? session?.editor.notice : nil)
            ?? session?.connection.lastError
    }
    var needsProxyRecovery: Bool { session?.connection.needsProxyRecovery ?? false }
    var initialized: Bool { session?.initialized == true && serviceConfigurationLoaded }
    var editingDisabled: Bool { !initialized || isManagingHelper || isSwitchingServer || session?.connection.editingDisabled == true }
    var requiresHelperInstallation: Bool {
        (defaultServer?.enhancedModeEnabled ?? false) && defaultServer?.enhancedBackend == .localTun && helperInstaller.status != .current
    }
    var canConnect: Bool { initialized && defaultServer != nil && !isManagingHelper && !requiresHelperInstallation && session?.connection.canConnect == true }
    var systemProxyActive: Bool { session?.connection.systemProxyActive == true }
    var interfaceSession: LocalTunInterfaceSession? { session?.connection.interfaceSession }
    var enhancedModeActive: Bool { session?.connection.enhancedModeActive == true }
    var activeCaptureDescription: String {
        var captures: [String] = []
        if session?.connection.systemProxyActive == true { captures.append("系统代理") }
        if session?.connection.enhancedModeActive == true { captures.append("增强模式") }
        return captures.joined(separator: " + ")
    }
    var needsConnectionCleanup: Bool { state == .recoveryRequired && session?.connection.hasOwnedResources == true }
    var canQuit: Bool { !isManagingHelper && !isSwitchingServer && session?.connection.hasOwnedResources != true && session?.connection.state != .stopping }

    init(makeSession: @escaping @MainActor () throws -> ApplicationSession = ApplicationServices.live,
         preferences: UserDefaults = .standard,
         helperInstaller: HelperInstallationManager? = nil) {
        self.makeSession = makeSession
        self.preferences = preferences
        automaticCaptureEnabled = preferences.bool(forKey: Self.automaticCaptureKey)
        self.helperInstaller = helperInstaller ?? HelperInstallationManager()
        serverList = ServerListPreferences(defaults: preferences)
        routing = RoutingPreferences(defaults: preferences)
        enhancedSetup = EnhancedModeOnboarding(preferences: preferences)
    }

    func initialize() async {
        guard !initializationStarted else { return }
        initializationStarted = true
        do {
            let application = try makeSession()
            // Publish recovery services before loading data that may fail to decode or unlock.
            session = application
            application.connection.onLog = { [weak self] in self?.log($0) }
            await application.initialize()
            if let data = preferences.data(forKey: Self.serviceConfigurationKey) {
                serviceConfiguration = try JSONDecoder().decode(ServiceConfiguration.self, from: data)
            } else {
                serviceConfiguration = ServiceConfiguration(profile: application.editor.profile)
                try persistServiceConfiguration()
            }
            serviceConfigurationLoaded = true
            if let notice = application.editor.notice { log(notice) }
            await helperInstaller.refresh()
            enhancedSetup.consider(hasInstallation: helperInstaller.status.isInstalled)
            if automaticCaptureEnabled { await connect() }
        } catch {
            initializationError = error.localizedDescription
            log(error.localizedDescription)
        }
    }

    func skipEnhancedSetup() {
        guard !isManagingHelper else { return }
        enhancedSetup.finish()
    }

    func installEnhancedSetup() async {
        await manageHelper(.install)
        if helperInstaller.status == .current { enhancedSetup.finish() }
    }

    func save() {
        guard let session, !editingDisabled else { return }
        do {
            session.editor.profile = profile
            try session.editor.save()
            try persistServiceConfiguration()
        }
        catch { log(error.localizedDescription) }
    }

    func updateSetting(_ text: String, field: SettingsField, profileID: UUID) throws {
        guard let session, !editingDisabled, profile.id == profileID else { throw CancellationError() }
        let updated = try SettingsInput.applying(text, field: field, to: profile)
        profile = updated
        do { try session.editor.save(); try persistServiceConfiguration() }
        catch { log(error.localizedDescription); throw error }
    }

    @discardableResult
    func selectServer(_ id: UUID) -> Bool {
        guard let session, !editingDisabled else { return false }
        do { try session.editor.edit(id); return true }
        catch { session.editor.report(error); log(error.localizedDescription); return false }
    }

    func setCapture(enhanced: Bool, enabled: Bool) async {
        guard canChangeCapture, let session, let current = defaultServer else { return }
        var next = current
        // Legacy capture preferences describe configuration, not a previous request to start automatically.
        if !automaticCaptureEnabled {
            next.enhancedModeEnabled = false
            next.systemProxyEnabled = false
        }
        if enhanced { next.enhancedModeEnabled = enabled }
        else { next.systemProxyEnabled = enabled }
        let shouldRun = next.enhancedModeEnabled || next.systemProxyEnabled
        do {
            if session.editor.profile.id == current.id && session.editor.hasChanges { try session.editor.save() }
            if shouldRun {
                try routing.configuration.validateCapture(systemProxy: next.systemProxyEnabled,
                    enhanced: next.enhancedModeEnabled, backend: next.enhancedBackend)
                _ = try next.coreConfiguration(credentials: session.editor.credentialsForMeasurement(current.id))
            }
            isSwitchingServer = true
            isUpdatingCapture = true
            defer { isSwitchingServer = false; isUpdatingCapture = false }
            serviceConfiguration = ServiceConfiguration(profile: next)
            try persistServiceConfiguration()
            automaticCaptureEnabled = shouldRun
            preferences.set(shouldRun, forKey: Self.automaticCaptureKey)
            if state == .connected || state == .connecting { await disconnect() }
            guard session.connection.canConnect else { return }
            if shouldRun { await connect() }
        } catch { session.editor.report(error); log(error.localizedDescription) }
    }

    /// Persists LAN listener exposure and restarts an active proxy to apply the binding change.
    func setLANSharing(_ enabled: Bool) async {
        guard !editingDisabled else { return }
        do {
            var next = profile
            next.allowLAN = enabled
            profile = next
            try persistServiceConfiguration()
            if state == .connected { await reconnect() }
        } catch { session?.editor.report(error) }
    }

    /// Records the bundled core’s supported automatic group policies.
    private(set) var poolCapabilities = CorePoolCapabilities.unavailable

    /// Refreshes feature gating from the bundled executable without opening proxy listeners.
    func refreshPoolCapabilities() async {
        do { poolCapabilities = try CorePoolCapabilities.parse(await CoreCapabilityProbe.read()) }
        catch is CancellationError { return }
        catch {
            poolCapabilities = .unavailable
            log(error.localizedDescription)
        }
    }

    /// Selects a group through the same transactional lifecycle as a single server.
    func useServerGroup(_ id: UUID, member: UUID? = nil) async {
        guard canChooseServer, let group = routing.configuration.groups.first(where: { $0.id == id }), poolCapabilities.supports(group.kind),
              let chosen = member ?? group.selectedID ?? group.members.first,
              group.members.contains(chosen), servers.contains(where: { $0.id == chosen }) else { return }
        if group.kind != .select && (profile.enhancedModeEnabled || !profile.systemProxyEnabled) {
            policyNotice = localized("自动服务器组目前仅支持系统代理，请关闭增强模式。")
            return
        }
        await applyFinalPolicy(serverID: chosen, groupID: id)
    }

    func useServer(_ id: UUID) async { await applyFinalPolicy(serverID: id) }


    /// Applies a FINAL choice without losing its previous server or leaving a failed live switch selected.
    private func applyFinalPolicy(serverID: UUID, groupID: UUID? = nil) async {
        guard canChooseServer, let session else { return }
        let previousID = session.editor.library.selectedID
        let previousOutbound = routing.configuration.finalOutbound
        let nextOutbound: OutboundTarget = groupID.map { .group($0) } ?? .server(serverID)
        let previousGroup = routing.configuration.groups.first { $0.id == groupID }
        let memberChanged = previousGroup.map { $0.kind == .select && $0.selectedID != serverID } ?? false
        let previousAction = routing.configuration.finalAction
        let nextAction: AddressRuleAction = .proxy
        guard previousAction != nextAction || serverID != previousID || previousOutbound != nextOutbound || memberChanged else { return }
        let wasRunning = state == .connected
        isSwitchingServer = true
        policyNotice = nil
        defer { isSwitchingServer = false }
        do {
            if session.editor.hasChanges { try session.editor.save() }
            guard let saved = session.editor.library.profiles.first(where: { $0.id == serverID }) else {
                throw ConfigurationError.invalid("服务器已不存在。")
            }
            let target = serviceConfiguration?.applying(to: saved) ?? saved
            var nextRouting = routing.configuration
            nextRouting.finalAction = nextAction
            try nextRouting.validateCapture(systemProxy: target.systemProxyEnabled,
                enhanced: target.enhancedModeEnabled, backend: target.enhancedBackend)
            if wasRunning {
                _ = try target.coreConfiguration(credentials: session.editor.credentialsForMeasurement(target.id))
            } else { try target.validate(requireCapture: false) }
            try routing.update { configuration in
                configuration.finalAction = nextAction
                configuration.finalOutbound = nextOutbound
                if memberChanged, let index = configuration.groups.firstIndex(where: { $0.id == groupID }) {
                    configuration.groups[index].selectedID = serverID
                }
            }
            if wasRunning {
                await disconnect()
                guard session.connection.canConnect else {
                    throw ConfigurationError.invalid(errorMessage ?? localized("出口切换失败"))
                }
            }
            try session.editor.select(serverID)
            if (wasRunning || automaticCaptureEnabled) && defaultServer != nil {
                await connect()
                if wasRunning && state != .connected {
                    throw ConfigurationError.invalid(errorMessage ?? localized("出口切换失败"))
                }
            }
        } catch {
            let failure = error
            do {
                try routing.update { configuration in
                    configuration.finalAction = previousAction
                    configuration.finalOutbound = previousOutbound
                    if memberChanged, let previousGroup,
                       let index = configuration.groups.firstIndex(where: { $0.id == previousGroup.id }) {
                        configuration.groups[index].selectedID = previousGroup.selectedID
                    }
                }
                if let previousID, session.editor.library.selectedID != previousID { try session.editor.select(previousID) }
                if wasRunning && session.connection.canConnect { await connect() }
            } catch { log(error.localizedDescription) }
            if wasRunning {
                policyNotice = localized(state == .connected
                    ? "出口切换失败，已恢复原出口。" : "出口切换失败，服务已停止。") + " " + localized(failure.localizedDescription)
            }
            if state != .connected || !wasRunning { session.editor.report(failure) }
            log(failure.localizedDescription)
        }
    }

    private func persistServiceConfiguration() throws {
        guard let serviceConfiguration else { return }
        preferences.set(try JSONEncoder().encode(serviceConfiguration), forKey: Self.serviceConfigurationKey)
    }

    @discardableResult
    func addServer() -> Bool {
        guard let session, !editingDisabled else { return false }
        do {
            try session.editor.add()
            session.editor.profile.name = localized("新服务器")
            return true
        }
        catch { session.editor.report(error); log(error.localizedDescription); return false }
    }

    @discardableResult
    func removeServer() -> Bool { removeServer(profile.id) }

    @discardableResult
    func removeServer(_ id: UUID) -> Bool {
        guard let session, !editingDisabled else { return false }
        do {
            try session.editor.remove(id)
            serverList.remove(id)
            return true
        }
        catch { session.editor.report(error); log(error.localizedDescription); return false }
    }


    func connect() async {
        guard canConnect, let session else { return }
        do {
            if session.editor.profile.id == session.editor.library.selectedID && session.editor.hasChanges {
                try session.editor.save()
            }
            try persistServiceConfiguration()
            guard let profile = defaultServer else { return }
            let credentials = try session.editor.credentialsForMeasurement(profile.id)
            var selectedRouting = routing.configuration
            selectedRouting.mode = .native
            try selectedRouting.validateCapture(systemProxy: profile.systemProxyEnabled, enhanced: profile.enhancedModeEnabled, backend: profile.enhancedBackend)
            var base = try profile.coreConfiguration(credentials: credentials)
            if case let .group(id) = selectedRouting.finalOutbound {
                guard let group = selectedRouting.groups.first(where: { $0.id == id }) else { throw ConfigurationError.invalid("服务器组已不存在。") }
                if group.kind != .select {
                    guard !profile.enhancedModeEnabled, profile.systemProxyEnabled else { throw ConfigurationError.invalid("自动服务器组目前仅支持系统代理，请关闭增强模式。") }
                    let capabilities = try CorePoolCapabilities.parse(await CoreCapabilityProbe.read())
                    poolCapabilities = capabilities
                    var secrets: [UUID: Credentials] = [:]
                    for member in group.members { secrets[member] = try session.editor.credentialsForMeasurement(member) }
                    base = try ClientPoolConfiguration.applying(to: base, group: group, servers: servers, credentials: secrets, capabilities: capabilities)
                }
            }
            var core = try DesktopCoreConfiguration.object(base)
            core["desktopBypassLocalNetworks"] = selectedRouting.bypassLocalNetworks
            let configuration = try JSONSerialization.data(withJSONObject: core)
            session.editor.clearNotice()
            let connectedID = profile.id
            await session.connection.connect(profile: profile, configuration: configuration, credentials: credentials, routing: selectedRouting)
            if session.connection.state == .connected {
                connectedRouting = selectedRouting
                if selectedRouting.finalAction != .direct { serverList.recordUse(connectedID) }
            }
        } catch {
            session.editor.report(error)
            log(error.localizedDescription)
        }
    }

    func reconnect() async {
        guard state == .connected, !isSwitchingServer else { return }
        do { try routing.configuration.validateCapture(systemProxy: profile.systemProxyEnabled, enhanced: profile.enhancedModeEnabled, backend: profile.enhancedBackend) }
        catch { session?.editor.report(error); return }
        await disconnect()
        if canConnect { await connect() }
    }

    func disconnect() async {
        guard let session else { return }
        session.editor.clearNotice()
        await session.connection.disconnect()
    }

    func recoverProxy() async {
        guard let session else { return }
        session.editor.clearNotice()
        await session.connection.recoverProxy()
    }

    func manageHelper(_ operation: HelperInstallationOperation) async {
        guard initialized, !isManagingHelper, !isSwitchingServer else { return }
        isManagingHelper = true
        defer { isManagingHelper = false }
        await disconnect()
        guard session?.connection.hasOwnedResources != true else {
            helperInstaller.report("请先完成当前连接的网络恢复，再安装或卸载后台。")
            return
        }
        let succeeded = await helperInstaller.perform(operation)
        isManagingHelper = false
        if succeeded && operation == .install && automaticCaptureEnabled { await connect() }
    }

    /// Changes only the selected backend; enabling capture remains a separate user action.
    func selectEnhancedBackend(_ backend: EnhancedBackend) {
        guard !editingDisabled, backend != profile.enhancedBackend, EnhancedBackend.allCases.contains(backend) else { return }
        var next = profile
        next.enhancedBackend = backend
        next.enhancedModeEnabled = false
        profile = next
        do { try persistServiceConfiguration() }
        catch { session?.editor.report(error) }
    }

    func clearLogs() { logs.removeAll() }

    private func log(_ text: String) {
        logs.append("\(Date.now.formatted(date: .omitted, time: .standard))  \(text)")
        if logs.count > 150 { logs.removeFirst(logs.count - 150) }
    }
}
