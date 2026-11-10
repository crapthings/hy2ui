import Foundation
import NetworkExtension
import Darwin

/// Forwards a session's packets through one Rust handle confined to the provider lifecycle queue.
final class PacketEngine: @unchecked Sendable {
    private let queue: DispatchQueue
    private var handle: OpaquePointer?
    private var timer: DispatchSourceTimer?
    private var session: UUID?
    private var pending: [Data] = []
    private var pendingIndex = 0
    private var reading = false
    private var started = false
    private var drainScheduled = false
    private var deadline = ContinuousClock.now
    private var completion: ((Result<String, Error>) -> Void)?
    private var remoteAddress = ""
    private var failure: ((Error) -> Void)?
    private var flow: NEPacketTunnelFlow?
    private var outputBuffer = [UInt8](repeating: 0, count: 65535)

    init(queue: DispatchQueue) { self.queue = queue }

    func start(session: UUID, configuration: Data, mtu: Int, completion: @escaping (Result<String, Error>) -> Void, failure: @escaping (Error) -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard self.session == nil else { completion(.failure(ConfigurationError.invalid("隧道已启动。"))); return }
        guard (1280...1500).contains(mtu) else { completion(.failure(ConfigurationError.invalid("MTU 无效。"))); return }
        self.session = session
        self.completion = completion
        self.failure = failure
        started = false
        deadline = .now + .seconds(25)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let resolution = Result { try CoreEndpoint.resolve(configuration: configuration) }
            self?.queue.async { [weak self] in
                guard let self, self.session == session else { return }
                switch resolution {
                case let .success(resolved): self.startNative(configuration: resolved.configuration, address: resolved.address, mtu: mtu)
                case let .failure(error): self.fail(error)
                }
            }
        }
    }

    private func startNative(configuration: Data, address: String, mtu: Int) {
        remoteAddress = address
        var error = [UInt8](repeating: 0, count: 2048)
        let engine = configuration.withUnsafeBytes { bytes in
            hy2_start(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, UInt16(mtu), &error, 2048)
        }
        guard let engine else {
            fail(ConfigurationError.invalid(String(decoding: error.prefix(while: { $0 != 0 }), as: UTF8.self)))
            return
        }
        handle = engine
    }

    @discardableResult
    func attach(flow: NEPacketTunnelFlow, session: UUID) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard self.session == session, handle != nil, started else { return false }
        self.flow = flow
        readPackets()
        tick()
        return self.session == session
    }

    func stop(session: UUID? = nil) {
        dispatchPrecondition(condition: .onQueue(queue))
        if let session, self.session != session { return }
        cleanup()
    }

    private func tick() {
        guard let handle else {
            if session != nil && ContinuousClock.now >= deadline {
                fail(ConfigurationError.invalid("服务器 DNS 解析超时。"))
            }
            return
        }
        switch hy2_state(handle) {
        case Hy2EngineStateFailed, Hy2EngineStateStopped:
            var bytes = [UInt8](repeating: 0, count: 2048)
            hy2_error(handle, &bytes, bytes.count)
            let text = String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
            fail(ConfigurationError.invalid(text.isEmpty ? "Rust 数据包引擎已停止。" : text))
            return
        case Hy2EngineStateConnected:
            if !started {
                started = true
                let callback = completion
                completion = nil
                callback?(.success(remoteAddress))
            }
        case Hy2EngineStateConnecting:
            if ContinuousClock.now >= deadline { fail(ConfigurationError.invalid("Hysteria 服务器连接超时。")) }
            return
        default:
            fail(ConfigurationError.invalid("Rust 数据包引擎状态无效。"))
            return
        }
        guard !drainScheduled else { return }
        drainOutput()
        flushInput()
    }

    private func drainOutput() {
        guard let handle, let flow else { return }
        let batchLimit = 64
        var packets: [Data] = []
        var families: [NSNumber] = []
        for _ in 0..<batchLimit {
            let count = hy2_read(handle, &outputBuffer, 65535)
            if count == Hy2ReadStatusEmpty.rawValue { break }
            guard count > 0 else { fail(ConfigurationError.invalid("Rust 数据包输出已关闭。")); return }
            packets.append(Data(outputBuffer.prefix(Int(count))))
            families.append(NSNumber(value: outputBuffer[0] >> 4 == 6 ? AF_INET6 : AF_INET))
        }
        guard packets.isEmpty || flow.writePackets(packets, withProtocols: families) else {
            fail(ConfigurationError.invalid("无法向系统写入隧道数据包。"))
            return
        }
        if packets.count == batchLimit { scheduleDrain() }
    }

    private func scheduleDrain() {
        guard !drainScheduled, let token = session else { return }
        drainScheduled = true
        // Yield after each batch so stop and settings callbacks are never starved by busy traffic.
        queue.async { [weak self] in
            guard let self, self.session == token else { return }
            self.drainScheduled = false
            self.tick()
        }
    }

    private func readPackets() {
        guard handle != nil, !reading, pending.isEmpty, let flow, let token = session else { return }
        reading = true
        flow.readPackets { [weak self] packets, _ in
            guard let self else { return }
            self.queue.async {
                guard self.session == token, self.handle != nil else { return }
                self.reading = false
                self.pending = packets
                self.pendingIndex = 0
                self.flushInput()
            }
        }
    }

    private func flushInput() {
        guard let handle else { return }
        while pendingIndex < pending.count {
            let result = pending[pendingIndex].withUnsafeBytes { bytes in
                hy2_write(handle, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
            }
            switch result {
            case Hy2WriteResultFull: return
            case Hy2WriteResultAccepted: pendingIndex += 1
            default: fail(ConfigurationError.invalid("Rust 数据包输入已关闭。")); return
            }
        }
        pending.removeAll(keepingCapacity: true)
        pendingIndex = 0
        readPackets()
    }

    private func fail(_ error: Error) {
        let startup = completion
        let runningFailure = failure
        completion = nil
        cleanup()
        if let startup { startup(.failure(error)) } else { runningFailure?(error) }
    }

    private func cleanup() {
        timer?.cancel()
        timer = nil
        session = nil
        flow = nil
        pending = []
        pendingIndex = 0
        reading = false
        started = false
        drainScheduled = false
        let startup = completion
        completion = nil
        failure = nil
        if let handle { hy2_stop(handle); self.handle = nil }
        startup?(.failure(CancellationError()))
    }
}
