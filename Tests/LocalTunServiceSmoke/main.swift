import Foundation
import Darwin

/// Signals deterministic fixture milestones without sleeps or privileged networking.
@MainActor
private final class FixtureGate {
    private var opened = false
    private var waiters: [UUID: (CheckedContinuation<Void, Error>, Task<Void, Never>)] = [:]
    func wait() async throws {
        guard !opened else { return }
        let id = UUID()
        try await withCheckedThrowingContinuation { continuation in
            let timeout = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(10)) }
                catch { return }
                guard let waiter = self?.waiters.removeValue(forKey: id) else { return }
                waiter.0.resume(throwing: LocalTunTransportError.timedOut)
            }
            waiters[id] = (continuation, timeout)
        }
    }
    func open() {
        opened = true
        let current = waiters.values
        waiters = [:]
        current.forEach { $0.1.cancel(); $0.0.resume() }
    }

}

/// Hosts a bounded mock helper over a private temporary Unix socket owned by the current test user.
private final class MockHelper: @unchecked Sendable {
    let path: String
    private let directory: URL
    private let listener: Int32
    private let complete: AsyncStream<String?>
    private let completion: AsyncStream<String?>.Continuation

    init(connections: Int, body: @escaping @Sendable (Int32, Int) throws -> Void) throws {
        directory = URL(fileURLWithPath: "/tmp/hy2-service-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        path = directory.appendingPathComponent("socket").path
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw LocalTunTransportError.unavailable }
        var sink: AsyncStream<String?>.Continuation!
        complete = AsyncStream(bufferingPolicy: .bufferingOldest(1)) { sink = $0 }
        completion = sink
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8CString).map { UInt8(bitPattern: $0) }
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw LocalTunTransportError.unavailable }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let status = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard status == 0, listen(listener, 4) == 0 else { throw LocalTunTransportError.unavailable }
        let server = listener
        let output = completion
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                for index in 0..<connections {
                    var event = pollfd(fd: server, events: Int16(POLLIN), revents: 0)
                    guard poll(&event, 1, 5000) > 0 else { throw LocalTunTransportError.timedOut }
                    let client = accept(server, nil, nil)
                    guard client >= 0 else { throw LocalTunTransportError.closed }
                    defer { close(client) }
                    var flag: Int32 = 1
                    _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &flag, socklen_t(MemoryLayout<Int32>.size))
                    var timeout = timeval(tv_sec: 5, tv_usec: 0)
                    _ = setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                    try body(client, index)
                }
                output.yield(nil)
            } catch { output.yield(error.localizedDescription) }
            output.finish()
        }
    }

    deinit { close(listener); unlink(path); try? FileManager.default.removeItem(at: directory) }

    func finish() async {
        for await error in complete { precondition(error == nil, error ?? "fixture failure") }
    }

    static func read(_ descriptor: Int32) throws -> LocalTunRequest? {
        let deadline = ContinuousClock.now + .seconds(5)
        var data = Data()
        while ContinuousClock.now < deadline {
            var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&event, 1, 100) > 0 else { continue }
            var byte: UInt8 = 0
            let count = recv(descriptor, &byte, 1, 0)
            if count == 0 { return nil }
            guard count == 1 else { throw LocalTunTransportError.closed }
            if byte == 10 { return try LocalTunMessageCodec.decodeRequest(data) }
            data.append(byte)
            guard data.count <= LocalTunWire.maxMessageBytes else { throw LocalTunProtocolError.messageTooLarge }
        }
        throw LocalTunTransportError.timedOut
    }

    static func send(_ event: LocalTunEvent, to descriptor: Int32) throws {
        let data = try LocalTunMessageCodec.encode(event)
        // Split writes exercise framing without relying on a particular read boundary.
        for part in [Data(data.prefix(3)), Data(data.dropFirst(3))] {
            var offset = 0
            while offset < part.count {
                let count = part.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress!.advanced(by: offset), $0.count - offset, 0) }
                guard count > 0 else { throw LocalTunTransportError.closed }
                offset += count
            }
        }
    }
}

/// Exercises local service cancellation, identity checks, and cleanup confirmation with unprivileged mock helpers.
@main
private struct LocalTunServiceSmoke {
    @MainActor
    static func main() async throws {
        try await normalLifecycleUsesFrozenEndpoint()
        try await cancelledStartupRequiresCleanupAcknowledgement()
        try await rejectsUnexpectedServerIdentity()
        try await ambiguousDisconnectRequiresRetryAcknowledgement()
        try await typedWorkerFailurePreservesRecoveryOwnership()
        try await coreDisconnectAndReconnectAreObservedInOrder()
        print("LocalTunService frozen endpoint, concurrent stop, cancellation recovery and peer identity checks passed.")
    }

    @MainActor
    private static func profile() -> Profile {
        var profile = Profile()
        profile.host = "original.example.com"
        profile.systemProxyEnabled = false
        profile.enhancedModeEnabled = true
        return profile
    }

    private static func frozenConfiguration() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["server": "203.0.113.8:443", "auth": "test-secret", "tls": ["sni": "tls.example.com"]])
    }

    @MainActor
    private static func normalLifecycleUsesFrozenEndpoint() async throws {
        let helper = try MockHelper(connections: 1) { descriptor, _ in
            guard let request = try MockHelper.read(descriptor), request.command == .start,
                  request.configuration?.host == "203.0.113.8",
                  request.configuration?.serverName == "tls.example.com" else { throw LocalTunProtocolError.invalidMessage }
            try MockHelper.send(LocalTunEvent(kind: .ready), to: descriptor)
            guard try MockHelper.read(descriptor)?.command == .stop else { throw LocalTunProtocolError.invalidMessage }
            try MockHelper.send(LocalTunEvent(kind: .stopped), to: descriptor)
        }
        let service = LocalTunService(socketPath: helper.path, expectedUID: getuid())
        var connected = false
        service.onStatus = { if $0 == .connected { connected = true } }
        try await service.start(profile: profile(), configuration: frozenConfiguration())
        precondition(connected)
        async let first: Void = service.stop()
        async let second: Void = service.stop()
        _ = try await (first, second)
        await helper.finish()
    }

    @MainActor
    private static func cancelledStartupRequiresCleanupAcknowledgement() async throws {
        let accepted = FixtureGate()
        let helper = try MockHelper(connections: 2) { descriptor, index in
            let request = try MockHelper.read(descriptor)
            if index == 0 {
                guard request?.command == .start else { throw LocalTunProtocolError.invalidMessage }
                Task { @MainActor in accepted.open() }
                guard try MockHelper.read(descriptor)?.command == .stop else { throw LocalTunProtocolError.invalidMessage }
                try MockHelper.send(LocalTunEvent(kind: .error, message: "startup cancelled"), to: descriptor)
            } else {
                guard request?.command == .stop else { throw LocalTunProtocolError.invalidMessage }
                try MockHelper.send(LocalTunEvent(kind: .stopped), to: descriptor)
            }
        }
        let service = LocalTunService(socketPath: helper.path, expectedUID: getuid())
        let start = Task { try await service.start(profile: profile(), configuration: frozenConfiguration()) }
        try await accepted.wait()
        start.cancel()
        do { try await start.value; preconditionFailure("cancelled start must fail") }
        catch is CancellationError {}
        try await service.stop()
        await helper.finish()
    }

    @MainActor
    private static func rejectsUnexpectedServerIdentity() async throws {
        let helper = try MockHelper(connections: 1) { descriptor, _ in
            guard try MockHelper.read(descriptor) == nil else { throw LocalTunProtocolError.invalidMessage }
        }
        let service = LocalTunService(socketPath: helper.path, expectedUID: getuid() + 1)
        do {
            try await service.start(profile: profile(), configuration: frozenConfiguration())
            preconditionFailure("untrusted peer must fail before sending a start request")
        } catch LocalTunTransportError.untrustedPeer {}
        // No request was sent, so cleanup must not invent a second privileged operation.
        try await service.stop()
        await helper.finish()
    }

    @MainActor
    private static func ambiguousDisconnectRequiresRetryAcknowledgement() async throws {
        let lost = FixtureGate()
        let helper = try MockHelper(connections: 3) { descriptor, index in
            let request = try MockHelper.read(descriptor)
            if index == 0 {
                guard request?.command == .start else { throw LocalTunProtocolError.invalidMessage }
                try MockHelper.send(LocalTunEvent(kind: .ready), to: descriptor)
                // EOF intentionally carries no cleanup acknowledgement.
            } else {
                guard request?.command == .stop else { throw LocalTunProtocolError.invalidMessage }
                let event = LocalTunEvent(kind: index == 1 ? .error : .stopped, message: index == 1 ? "cleanup failed" : nil)
                try MockHelper.send(event, to: descriptor)
            }
        }
        let service = LocalTunService(socketPath: helper.path, expectedUID: getuid())
        var disconnected = 0
        service.onStatus = { status in
            if status == .recoveryRequired { lost.open() }
            if status == .disconnected { disconnected += 1 }
        }
        try await service.start(profile: profile(), configuration: frozenConfiguration())
        try await lost.wait()
        do { try await service.stop(); preconditionFailure("missing cleanup acknowledgement must fail") }
        catch is LocalTunFailure {}
        precondition(disconnected == 0, "ambiguous EOF and failed cleanup must retain ownership")
        try await service.stop()
        precondition(disconnected > 0)
        await helper.finish()
    }

    @MainActor
    private static func typedWorkerFailurePreservesRecoveryOwnership() async throws {
        let failed = FixtureGate()
        let helper = try MockHelper(connections: 2) { descriptor, index in
            let request = try MockHelper.read(descriptor)
            if index == 0 {
                guard request?.command == .start else { throw LocalTunProtocolError.invalidMessage }
                try MockHelper.send(LocalTunEvent(kind: .ready), to: descriptor)
                try MockHelper.send(LocalTunEvent(kind: .error, message: "raw-secret-must-not-be-logged",
                    failure: LocalTunFailure(.workerExited, exitStatus: 9, terminatedBySignal: true)), to: descriptor)
            } else {
                guard request?.command == .stop else { throw LocalTunProtocolError.invalidMessage }
                try MockHelper.send(LocalTunEvent(kind: .stopped), to: descriptor)
            }
        }
        let service = LocalTunService(socketPath: helper.path, expectedUID: getuid())
        var logs: [String] = []
        var statuses: [VPNConnectionStatus] = []
        service.onLog = { logs.append($0) }
        service.onStatus = { status in
            statuses.append(status)
            if status == .recoveryRequired { failed.open() }
        }
        try await service.start(profile: profile(), configuration: frozenConfiguration())
        try await failed.wait()
        precondition(!statuses.contains(.reasserting), "service falsely promised a reconnect")
        precondition(!statuses.contains(.disconnected), "failure released ownership without cleanup acknowledgement")
        precondition(logs.contains { $0.contains("exit=9") && $0.contains("signal=true") })
        precondition(!logs.contains { $0.contains("raw-secret") })
        try await service.stop()
        precondition(statuses.last == .disconnected)
        await helper.finish()
    }

    @MainActor
    private static func coreDisconnectAndReconnectAreObservedInOrder() async throws {
        let restored = FixtureGate()
        let helper = try MockHelper(connections: 1) { descriptor, _ in
            guard try MockHelper.read(descriptor)?.command == .start else { throw LocalTunProtocolError.invalidMessage }
            try MockHelper.send(LocalTunEvent(kind: .ready), to: descriptor)
            for event in [LocalTunCoreEvent.disconnected, .tcpConnectFailed, .connected] {
                try MockHelper.send(LocalTunEvent(kind: .log, message: "private-raw-upstream-text", coreEvent: event), to: descriptor)
            }
            guard try MockHelper.read(descriptor)?.command == .stop else { throw LocalTunProtocolError.invalidMessage }
            try MockHelper.send(LocalTunEvent(kind: .stopped), to: descriptor)
        }
        let service = LocalTunService(socketPath: helper.path, expectedUID: getuid())
        var statuses: [VPNConnectionStatus] = []
        var logs: [String] = []
        service.onLog = { logs.append($0) }
        service.onStatus = { status in
            statuses.append(status)
            if status == .connected && statuses.contains(.recoveryRequired) { restored.open() }
        }
        try await service.start(profile: profile(), configuration: frozenConfiguration())
        try await restored.wait()
        precondition(statuses == [.connecting, .connected, .recoveryRequired, .connected])
        precondition(!logs.contains { $0.contains("private-raw") })
        try await service.stop()
        precondition(statuses.last == .disconnected)
        await helper.finish()
    }

}
