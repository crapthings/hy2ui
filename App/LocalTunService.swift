import Foundation
import Darwin
#if SWIFT_PACKAGE
import Hy2Models
import Hy2Connection
#endif

/// Controls a generation-scoped local TUN session and confirms privileged cleanup before releasing ownership.
@MainActor
final class LocalTunService: VPNConnectionControlling {
    var onTelemetry: ((CoreTelemetryObservation) -> Void)?
    var onStatus: ((VPNConnectionStatus) -> Void)?
    var onLog: ((String) -> Void)?
    private let socketPath: String
    private let expectedUID: uid_t
    private var generation = UUID()
    private var transport: LocalTunTransport?
    private var consumer: Task<Void, Never>?
    private var ready: CheckedContinuation<Void, Error>?
    private var ended: [CheckedContinuation<Void, Never>] = []
    private var stopTask: Task<Void, Error>?
    private var ownershipMayExist = false

    init(socketPath: String = LocalTunWire.socketPath, expectedUID: uid_t = 0) {
        self.socketPath = socketPath
        self.expectedUID = expectedUID
    }

    deinit { consumer?.cancel(); transport?.abort() }

    func load() async throws {
        guard transport == nil, FileManager.default.fileExists(atPath: socketPath) else { return }
        try await confirmStopped(command: .status)
    }

    func start(profile: Profile, configuration: Data) async throws {
        try Task.checkCancellation()
        guard transport == nil, stopTask == nil, !ownershipMayExist else {
            throw ConfigurationError.invalid("本地增强模式正在运行或等待恢复。")
        }
        guard FileManager.default.fileExists(atPath: socketPath) else { throw LocalTunTransportError.unavailable }
        let payload = try LocalTunConfiguration.fromCore(configuration, profile: profile)
        let token = UUID()
        generation = token
        ownershipMayExist = true
        onStatus?(.connecting)
        let channel = LocalTunTransport(socketPath: socketPath, expectedUID: expectedUID,
            request: LocalTunRequest(command: .start, configuration: payload), startupTimeout: .seconds(40))
        transport = channel
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                ready = continuation
                if Task.isCancelled {
                    ready = nil
                    continuation.resume(throwing: CancellationError())
                    channel.requestStop()
                }
                consume(channel, token: token)
                channel.launch()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.cancelPendingActivation()
            }
        }
    }

    func cancelPendingActivation() {
        ready?.resume(throwing: CancellationError())
        ready = nil
        transport?.requestStop()
    }

    func stop() async throws {
        if let stopTask { try await stopTask.value; return }
        let task = Task { @MainActor in
            self.cancelPendingActivation()
            if self.transport != nil {
                await withCheckedContinuation { self.ended.append($0) }
            }
            if self.ownershipMayExist { try await self.confirmStopped(command: .stop) }
            self.onStatus?(.disconnected)
        }
        stopTask = task
        defer { stopTask = nil }
        try await task.value
    }

    private func consume(_ channel: LocalTunTransport, token: UUID) {
        consumer = Task { @MainActor [weak self] in
            do {
                for try await event in channel.events {
                    guard let self, self.generation == token else { return }
                    self.receive(event)
                }
                self?.transportEnded(token: token, error: nil)
            } catch {
                self?.transportEnded(token: token, error: error)
            }
        }
    }

    private func receive(_ event: LocalTunEvent) {
        switch event.kind {
        case .ready:
            let continuation = ready
            ready = nil
            continuation?.resume()
            onStatus?(.connected)
        case .stopped:
            ownershipMayExist = false
            let continuation = ready
            ready = nil
            continuation?.resume(throwing: CancellationError())
            onStatus?(.disconnected)
        case .log:
            if let metrics = event.metrics {
                onTelemetry?(CoreTelemetryObservation(session: generation, metrics: metrics))
            } else if let coreEvent = event.coreEvent {
                onLog?(coreEvent.message)
                guard ready == nil, stopTask == nil else { return }
                if coreEvent == .disconnected { onStatus?(.recoveryRequired) }
                if coreEvent == .connected { onStatus?(.connected) }
            } else if let message = event.message { onLog?(String(message.prefix(2000))) }
        case .error:
            onLog?((event.failure ?? LocalTunFailure(.unknown)).diagnostic)
        }
    }

    private func transportEnded(token: UUID, error: Error?) {
        guard generation == token else { return }
        if transport?.requestMayHaveBeenSent != true { ownershipMayExist = false }
        transport = nil
        consumer = nil
        let continuation = ready
        ready = nil
        continuation?.resume(throwing: error ?? LocalTunTransportError.closed)
        if !ownershipMayExist { onStatus?(.disconnected) }
        if ownershipMayExist {
            onLog?(error?.localizedDescription ?? "本地增强模式连接已关闭，仍需确认网络恢复。")
            if stopTask == nil { onStatus?(.recoveryRequired) }
        }
        let waiters = ended
        ended = []
        waiters.forEach { $0.resume() }
    }

    private func confirmStopped(command: LocalTunCommand) async throws {
        let channel = LocalTunTransport(socketPath: socketPath, expectedUID: expectedUID,
            request: LocalTunRequest(command: command), startupTimeout: .seconds(15))
        defer { channel.abort() }
        do {
            try await withTaskCancellationHandler {
                channel.launch()
                var confirmed = false
                for try await event in channel.events {
                    if event.kind == .stopped { confirmed = true }
                    if event.kind == .error { throw event.failure ?? LocalTunFailure(.unknown) }
                }
                guard confirmed else { throw LocalTunTransportError.closed }
                ownershipMayExist = false
            } onCancel: { channel.abort() }
        } catch {
            if channel.requestMayHaveBeenSent {
                ownershipMayExist = true
                if stopTask == nil { onStatus?(.recoveryRequired) }
            }
            throw error
        }
    }
}

/// Converts only supported core endpoint and secret fields into the helper's restricted configuration.
private extension LocalTunConfiguration {
    static func fromCore(_ data: Data, profile: Profile) throws -> LocalTunConfiguration {
        guard let core = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let server = core["server"] as? String,
              let endpoint = URLComponents(string: "https://" + server),
              let rawHost = endpoint.host, let port = endpoint.port,
              let password = core["auth"] as? String else { throw LocalTunProtocolError.invalidConfiguration }
        let tls = core["tls"] as? [String: Any]
        let obfs = core["obfs"] as? [String: Any]
        let salamander = obfs?["salamander"] as? [String: Any]
        let payload = LocalTunConfiguration(host: rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), port: port,
            serverName: tls?["sni"] as? String ?? profile.serverName, password: password,
            obfuscationPassword: salamander?["password"] as? String ?? "", mtu: profile.mtu, dns: profile.dns,
            directProcesses: core["desktopDirectProcesses"] as? [String],
            bypassLocalNetworks: core["desktopBypassLocalNetworks"] as? Bool, addressRules: core["desktopAddressRules"] as? [String])
        try payload.validate()
        return payload
    }
}
