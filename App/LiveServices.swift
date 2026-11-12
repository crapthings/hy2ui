import Foundation
#if SWIFT_PACKAGE
import Hy2Models
import Hy2Connection
#endif

/// Makes the concrete Rust process available through the coordinator's worker boundary.
extension CoreProcess: ProxyWorkerControlling {}

/// Makes journal-based proxy restoration available through the coordinator's proxy boundary.
extension SystemProxy: SystemProxyControlling {}

/// Makes Keychain-backed persistence available through the editor's repository boundary.
extension ProfileStore: ProfilePersisting {}

/// Rejects legacy extension requests because the official CLI is managed by the local TUN helper.
@MainActor
final class UnavailableExtensionService: VPNConnectionControlling {
    var onStatus: ((VPNConnectionStatus) -> Void)?
    var onLog: ((String) -> Void)?
    func load() async throws {}
    func start(profile: Profile, configuration: Data) async throws {
        throw ConfigurationError.invalid("官方 CLI 仅支持本地 TUN，请在设置中选择本地增强模式。")
    }
    func stop() async throws {}
    func cancelPendingActivation() {}
}

/// Constructs live application dependencies before any persisted profile or credentials are read.
@MainActor
enum ApplicationServices {
    static func live() throws -> ApplicationSession {
        let repository = try ProfileStore()
        let proxy = SystemProxy(directory: repository.directory)
        let connection = ConnectionCoordinator(
            worker: CoreProcess(), proxy: proxy, vpn: UnavailableExtensionService(),
            localTunnel: LocalTunService(),
            resolveProxyConfiguration: { configuration in
                try await Task.detached(priority: .userInitiated) {
                    try CoreEndpoint.resolve(configuration: configuration).configuration
                }.value
            }
        )
        return ApplicationSession(editor: ProfileEditor(repository: repository), connection: connection)
    }
}

/// Exposes unprivileged proxy telemetry through the optional connection metrics boundary.
extension CoreProcess: CoreTelemetryProviding {}

/// Exposes privileged TUN telemetry through the same generation-scoped metrics boundary.
extension LocalTunService: CoreTelemetryProviding {}

/// Makes native automatic proxy configuration available through the optional PAC boundary.
extension SystemProxy: PACProxyControlling {}
