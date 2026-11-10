import Foundation
import NetworkExtension
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

/// Translates Apple VPN callbacks into the coordinator's platform-independent lifecycle events.
@MainActor
final class VPNServiceAdapter: VPNConnectionControlling {
    var onStatus: ((VPNConnectionStatus) -> Void)?
    var onLog: ((String) -> Void)?
    private let service: VPNService

    init(service: VPNService) {
        self.service = service
        service.onLog = { [weak self] in self?.onLog?($0) }
        service.onStatus = { [weak self] status in
            let translated: VPNConnectionStatus
            switch status {
            case .invalid: translated = .invalid
            case .disconnected: translated = .disconnected
            case .connecting: translated = .connecting
            case .connected: translated = .connected
            case .reasserting: translated = .reasserting
            case .disconnecting: translated = .disconnecting
            @unknown default: return
            }
            self?.onStatus?(translated)
        }
    }

    func load() async throws { try await service.load() }
    func start(profile: Profile, configuration: Data) async throws {
        try await service.start(profile: profile, configuration: configuration)
    }
    func stop() async throws { try await service.stopAndWait() }
    func cancelPendingActivation() { service.cancelPendingActivation() }
}

/// Constructs live application dependencies before any persisted profile or credentials are read.
@MainActor
enum ApplicationServices {
    static func live() throws -> ApplicationSession {
        let repository = try ProfileStore()
        let proxy = SystemProxy(directory: repository.directory)
        let connection = ConnectionCoordinator(
            worker: CoreProcess(), proxy: proxy, vpn: VPNServiceAdapter(service: VPNService()),
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
