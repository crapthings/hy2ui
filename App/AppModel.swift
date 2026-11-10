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

    func localizedLog(_ value: String) -> String {
        guard let separator = value.range(of: "  ") else { return localized(value) }
        return String(value[..<separator.upperBound]) + localized(String(value[separator.upperBound...]))
    }

    private var session: ApplicationSession?
    private let makeSession: @MainActor () throws -> ApplicationSession
    private var initializationStarted = false
    private var draft = Profile()
    private var draftCredentials = Credentials()
    private var initializationError: String?
    let helperInstaller = HelperInstallationManager()
    let dashboard = DashboardModel()
    let routing: RoutingPreferences
    let enhancedSetup: EnhancedModeOnboarding
    private(set) var isManagingHelper = false
    private(set) var logs: [String] = []

    var profile: Profile {
        get { session?.editor.profile ?? draft }
        set {
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
    var hasServer: Bool { session?.editor.hasServer == true }
    var hasUnsavedChanges: Bool { session?.editor.hasChanges == true }

    var state: ConnectionState { session?.connection.state ?? .idle }
    var editorNotice: String? { session?.editor.notice }
    var errorMessage: String? {
        initializationError ?? (session?.editor.noticeIsError == true ? session?.editor.notice : nil)
            ?? session?.connection.lastError
    }
    var needsProxyRecovery: Bool { session?.connection.needsProxyRecovery ?? false }
    var initialized: Bool { session?.initialized ?? false }
    var editingDisabled: Bool { !initialized || isManagingHelper || session?.connection.editingDisabled == true }
    var requiresHelperInstallation: Bool {
        profile.enhancedModeEnabled && profile.enhancedBackend == .localTun && helperInstaller.status != .current
    }
    var canConnect: Bool { initialized && hasServer && !isManagingHelper && !requiresHelperInstallation && session?.connection.canConnect == true }
    var systemProxyActive: Bool { session?.connection.systemProxyActive == true }
    var enhancedModeActive: Bool { session?.connection.enhancedModeActive == true }
    var activeCaptureDescription: String {
        var captures: [String] = []
        if session?.connection.systemProxyActive == true { captures.append("系统代理") }
        if session?.connection.enhancedModeActive == true { captures.append("增强模式") }
        return captures.joined(separator: " + ")
    }
    var needsConnectionCleanup: Bool { state == .recoveryRequired && session?.connection.hasOwnedResources == true }
    var canQuit: Bool { !isManagingHelper && session?.connection.hasOwnedResources != true && session?.connection.state != .stopping }

    init(makeSession: @escaping @MainActor () throws -> ApplicationSession = ApplicationServices.live,
         preferences: UserDefaults = .standard) {
        self.makeSession = makeSession
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
            application.connection.onTelemetry = { [weak self] source, observation in
                self?.dashboard.receive(observation, source: source)
            }
            dashboard.start()
            await application.initialize()
            if let notice = application.editor.notice { log(notice) }
            await helperInstaller.refresh()
            enhancedSetup.consider(hasInstallation: helperInstaller.status.isInstalled)
        } catch {
            initializationError = error.localizedDescription
            log(error.localizedDescription)
        }
    }

    func showEnhancedSetup() {
        guard initialized, !isManagingHelper else { return }
        enhancedSetup.show()
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
        do { try session.editor.save() }
        catch { log(error.localizedDescription) }
    }

    func updateSetting(_ text: String, field: SettingsField, profileID: UUID) throws {
        guard let session, !editingDisabled, profile.id == profileID else { throw CancellationError() }
        let updated = try SettingsInput.applying(text, field: field, to: profile)
        session.editor.profile = updated
        do { try session.editor.save() }
        catch { log(error.localizedDescription); throw error }
    }

    @discardableResult
    func selectServer(_ id: UUID) -> Bool {
        guard let session, !editingDisabled else { return false }
        do { try session.editor.select(id); return true }
        catch { session.editor.report(error); log(error.localizedDescription); return false }
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

    func measureServer(_ server: Profile) async -> Int? {
        guard initialized, let session else { return nil }
        do {
            let secrets = try session.editor.credentialsForMeasurement(server.id)
            // Probe connection settings independently from capture choices and local listener ports.
            var probe = server
            probe.systemProxyEnabled = true; probe.enhancedModeEnabled = false
            probe.httpPort = 18080; probe.socksPort = 11080
            let configuration = try probe.coreConfiguration(credentials: secrets)
            try Task.checkCancellation()
            return await ServerLatencyProbe.measure(configuration: configuration, credentials: secrets)
        } catch { return nil }
    }

    func connect() async {
        guard canConnect, let session else { return }
        do {
            try routing.configuration.validateCapture(systemProxy: profile.systemProxyEnabled, enhanced: profile.enhancedModeEnabled, backend: profile.enhancedBackend)
            let base = try profile.coreConfiguration(credentials: credentials)
            var core = try JSONSerialization.jsonObject(with: base) as? [String: Any] ?? [:]
            if !routing.configuration.directProcesses.isEmpty { core["desktopDirectProcesses"] = routing.configuration.directProcesses }
            let configuration = try JSONSerialization.data(withJSONObject: core)
            try session.editor.save()
            session.editor.clearNotice()
            let connectedID = profile.id
            await session.connection.connect(profile: profile, configuration: configuration, credentials: credentials, routing: routing.configuration)
            if session.connection.state == .connected { serverList.recordUse(connectedID) }
        } catch {
            session.editor.report(error)
            log(error.localizedDescription)
        }
    }

    func disconnect() async {
        guard let session else { return }
        session.editor.clearNotice()
        await session.connection.disconnect()
        dashboard.clearLive()
    }

    func recoverProxy() async {
        guard let session else { return }
        session.editor.clearNotice()
        await session.connection.recoverProxy()
    }

    func manageHelper(_ operation: HelperInstallationOperation) async {
        guard initialized, !isManagingHelper else { return }
        isManagingHelper = true
        defer { isManagingHelper = false }
        await disconnect()
        guard session?.connection.hasOwnedResources != true else {
            helperInstaller.report("请先完成当前连接的网络恢复，再安装或卸载后台。")
            return
        }
        _ = await helperInstaller.perform(operation)
    }

    private func log(_ text: String) {
        logs.append("\(Date.now.formatted(date: .omitted, time: .standard))  \(text)")
        if logs.count > 150 { logs.removeFirst(logs.count - 150) }
    }
}
