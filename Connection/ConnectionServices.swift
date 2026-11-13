import Foundation
#if SWIFT_PACKAGE
import Hy2Models
#endif

/// Describes the resource lifecycle independently from errors displayed to the user.
public enum ConnectionState: Equatable, Sendable {
    case idle, connecting, connected, stopping, recoveryRequired

    public var title: String {
        switch self {
        case .idle: "未连接"
        case .connecting: "正在连接"
        case .connected: "已连接"
        case .stopping: "正在断开"
        case .recoveryRequired: "需要恢复"
        }
    }
}

/// Represents the VPN statuses needed by the lifecycle coordinator without importing Apple frameworks.
public enum VPNConnectionStatus: Equatable, Sendable {
    case invalid, disconnected, connecting, connected, reasserting, disconnecting, recoveryRequired
}

/// Provides an injectable lifecycle boundary for the local Rust proxy worker.
@MainActor
public protocol ProxyWorkerControlling: AnyObject {
    var onExit: (() -> Void)? { get set }
    var onLog: ((String) -> Void)? { get set }
    var isRunning: Bool { get }
    func start(configuration: Data, credentials: Credentials) async throws
    func stop() async
}

/// Provides journal-aware system proxy configuration and restoration.
@MainActor
public protocol SystemProxyControlling: AnyObject {
    var needsRecovery: Bool { get }
    func enable(httpPort: Int, socksPort: Int, routing: RoutingConfiguration) async throws
    func restore() throws
}

/// Provides an injectable lifecycle boundary for the system-managed VPN connection.
@MainActor
public protocol VPNConnectionControlling: AnyObject {
    var onStatus: ((VPNConnectionStatus) -> Void)? { get set }
    var onLog: ((String) -> Void)? { get set }
    func load() async throws
    func start(profile: Profile, configuration: Data) async throws
    func stop() async throws
    func cancelPendingActivation()
}

/// Provides profile persistence independently of connection and recovery resources.
@MainActor
public protocol ProfilePersisting: AnyObject {
    func load() throws -> ServerLibrary
    func select(_ id: UUID) throws
    func remove(_ id: UUID) throws
    func save(_ profile: Profile, credentials: Credentials) throws
    func credentials(for profile: Profile) throws -> Credentials
}

/// Identifies independent core streams whose transport traffic can be safely added together.
public enum CoreTelemetrySource: String, Sendable { case proxy, localTun }

/// Supplies opt-in metric callbacks without expanding existing lifecycle test doubles.
@MainActor
public protocol CoreTelemetryProviding: AnyObject {
    var onTelemetry: ((CoreTelemetryObservation) -> Void)? { get set }
}

/// Enables automatic proxy selection without changing the manual proxy lifecycle boundary.
@MainActor
public protocol PACProxyControlling: AnyObject {
    func enablePAC(configuration: RoutingConfiguration, httpPort: Int) async throws
}

/// Exposes verified session identity without granting the UI raw interface or process control.
@MainActor
public protocol TunnelSessionProviding: AnyObject {
    var interfaceSession: LocalTunInterfaceSession? { get }
}
