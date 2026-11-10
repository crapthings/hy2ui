import Foundation
import Observation

/// Supplies read-only inspection and user-authorized execution as replaceable installer dependencies.
struct HelperInstallationDependencies: Sendable {
    let snapshot: @Sendable (URL) throws -> HelperInstallationSnapshot
    let status: @Sendable (URL) -> HelperInstallationStatus
    let authorize: @Sendable (String) async throws -> Void

    static let live = Self(
        snapshot: { try HelperInstallationProbe.snapshot(application: $0) },
        status: { HelperInstallationProbe.status(application: $0) },
        authorize: { try await HelperInstallerAuthorization.run(script: $0) }
    )
}

/// Coordinates user-authorized background installation without owning tunnel connection state.
@MainActor @Observable
final class HelperInstallationManager {
    private(set) var status = HelperInstallationStatus.checking
    private(set) var isBusy = false
    private(set) var message: String?
    private(set) var failed = false
    private let application: URL
    private let dependencies: HelperInstallationDependencies
    private var refreshID: UUID?

    init(application: URL = Bundle.main.bundleURL, dependencies: HelperInstallationDependencies = .live) {
        self.application = application
        self.dependencies = dependencies
    }

    var installButtonTitle: String {
        switch status {
        case .checking, .notInstalled: "安装"
        case .updateAvailable, .legacy: "更新"
        case .current, .damaged: "修复"
        case .otherUser: "重新安装"
        }
    }
    var canUninstall: Bool { status.isInstalled && !isBusy }

    func report(_ message: String) {
        self.message = message
        failed = true
    }

    func refresh() async {
        guard refreshID == nil, !isBusy else { return }
        let token = UUID()
        refreshID = token
        let application = application
        let dependencies = dependencies
        let result = await Task.detached(priority: .utility) { dependencies.status(application) }.value
        guard refreshID == token else { return }
        refreshID = nil
        if !isBusy { status = result }
    }

    func perform(_ operation: HelperInstallationOperation) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        refreshID = nil
        failed = false
        message = "等待 macOS 管理员授权…"
        do {
            try Task.checkCancellation()
            let application = application
            let dependencies = dependencies
            let snapshot = try await Task.detached(priority: .userInitiated) { try dependencies.snapshot(application) }.value
            try Task.checkCancellation()
            let encoded = operation == .install ? HelperInstallerPayload.install : HelperInstallerPayload.uninstall
            guard let data = Data(base64Encoded: encoded), let source = String(data: data, encoding: .utf8) else {
                throw HelperInstallationError.invalidPayload
            }
            let script = try HelperInstallationCommand.authorizationScript(operation: operation, installerSource: source,
                appPath: snapshot.application.path, manifest: snapshot.manifest)
            try await dependencies.authorize(script)
            status = await Task.detached(priority: .utility) { dependencies.status(application) }.value
            if operation == .install {
                guard status == .current else { throw HelperInstallationError.failed("安装操作已结束，但后台校验尚未通过，请点击刷新或重试修复。") }
                message = "后台已安装，可以开启增强模式。"
            } else {
                guard status == .notInstalled else { throw HelperInstallationError.failed("后台卸载尚未完成，请重试。") }
                message = "后台已卸载，节点配置和钥匙串凭据已保留。"
            }
            isBusy = false
            return true
        } catch {
            isBusy = false
            failed = !(error is CancellationError)
            if case HelperInstallationError.cancelled = error { failed = false }
            message = error is CancellationError ? HelperInstallationError.cancelled.localizedDescription : error.localizedDescription
            await refresh()
            return false
        }
    }
}
