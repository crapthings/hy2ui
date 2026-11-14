import Foundation
import Darwin

/// Serializes one packet core and applies bounded backpressure to a host-owned flow.
final class PacketAdapter: @unchecked Sendable {
    private enum State { case idle, starting, ready, active }
    private let queue = DispatchQueue(label: "dev.hy2ui.ne-packet-adapter", qos: .userInitiated)
    private let callbackQueue: DispatchQueue
    private let coreFactory: (Data) throws -> PacketCore
    private let onFailure: (Error) -> Void
    private let startupTimeout: Duration
    private let maxPendingPackets = 256
    private let maxPendingBytes = 1_048_576
    private let batchLimit = 64
    private var state = State.idle
    private var core: PacketCore?
    private var flow: TunnelPacketFlow?
    private var timer: DispatchSourceTimer?
    private var generation: UUID?
    private var startCompletion: ((Result<Void, Error>) -> Void)?
    private var startupKeepAlive: PacketAdapter?
    private var deadline = ContinuousClock.now
    private var nextStatus = ContinuousClock.now
    private var reading = false
    private var readSequence: UInt64 = 0
    private var pending: [Data] = []
    private var pendingIndex = 0
    private var pumpScheduled = false

    init(callbackQueue: DispatchQueue, startupTimeout: Duration = .seconds(25),
         coreFactory: @escaping (Data) throws -> PacketCore,
         onFailure: @escaping (Error) -> Void) {
        self.callbackQueue = callbackQueue
        self.startupTimeout = startupTimeout
        self.coreFactory = coreFactory
        self.onFailure = onFailure
    }

    deinit {
        timer?.cancel()
        if let orphan = core {
            // No queued operation retains this adapter now; never block its caller on Rust cleanup.
            DispatchQueue.global(qos: .utility).async {
                orphan.shutdown()
                try? orphan.destroy()
            }
        }
    }

    func start(configuration: Data, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            guard self.state == .idle else {
                self.deliver { completion(.failure(PacketEngineError.busy)) }
                return
            }
            self.state = .starting
            self.generation = UUID()
            self.startCompletion = completion
            self.startupKeepAlive = self
            self.deadline = ContinuousClock.now + self.startupTimeout
            do { self.core = try self.coreFactory(configuration) }
            catch { self.fail(error); return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
        }
    }

    func attach(flow: TunnelPacketFlow, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            guard self.state == .ready, self.core != nil else {
                self.deliver { completion(.failure(PacketEngineError.invalidState)) }
                return
            }
            self.flow = flow
            self.state = .active
            self.deliver { completion(.success(())) }
            self.requestRead()
            self.pump()
        }
    }

    func stop(completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            let startup = self.startCompletion
            self.startCompletion = nil
            let result = self.cleanup()
            if let startup { self.deliver { startup(.failure(PacketEngineError.cancelled)) } }
            self.deliver { completion(result) }
        }
    }

    private func tick() {
        guard state != .idle, let core else { return }
        if state == .starting || ContinuousClock.now >= nextStatus {
            do {
                let status = try core.status()
                nextStatus = ContinuousClock.now + .milliseconds(250)
                switch status.worker {
                case "failed": fail(PacketEngineError.coreFailed(status.errorCode)); return
                case "stopped": fail(PacketEngineError.outputClosed); return
                case "running": break
                default: fail(PacketEngineError.invalidCoreStatus); return
                }
                if state == .starting {
                    if status.connection == "failed" {
                        fail(PacketEngineError.coreFailed(status.errorCode))
                        return
                    }
                    if status.stackReady && status.connection == "connected" {
                        state = .ready
                        let startup = startCompletion
                        startCompletion = nil
                        startupKeepAlive = nil
                        if let startup { deliver { startup(.success(())) } }
                    } else if ContinuousClock.now >= deadline {
                        fail(PacketEngineError.startupTimedOut)
                        return
                    }
                }
            } catch { fail(error); return }
        }
        if state == .active { pump() }
    }

    private func requestRead() {
        guard state == .active, !reading, pending.isEmpty, let flow, let token = generation else { return }
        reading = true
        readSequence &+= 1
        let sequence = readSequence
        flow.readPackets { [weak self] packets, families in
            guard let self else { return }
            self.queue.async { [weak self] in
                guard let self, self.state == .active, self.generation == token,
                      self.reading, self.readSequence == sequence else { return }
                self.reading = false
                guard packets.count == families.count else { self.fail(PacketEngineError.invalidBatch); return }
                guard packets.count <= self.maxPendingPackets else { self.fail(PacketEngineError.packetBacklogExceeded); return }
                if packets.isEmpty {
                    self.queue.asyncAfter(deadline: .now() + .milliseconds(10)) { [weak self] in
                        guard let self, self.generation == token else { return }
                        self.requestRead()
                    }
                    return
                }
                var totalBytes = 0
                for (packet, family) in zip(packets, families) {
                    guard let expected = self.family(of: packet), expected == family else {
                        self.fail(PacketEngineError.invalidPacket)
                        return
                    }
                    totalBytes += packet.count
                    guard totalBytes <= self.maxPendingBytes else {
                        self.fail(PacketEngineError.packetBacklogExceeded)
                        return
                    }
                }
                self.pending = packets
                self.pendingIndex = 0
                self.pump()
            }
        }
    }

    private func pump() {
        guard state == .active, let core, let flow else { return }
        do {
            var submitted = 0
            while pendingIndex < pending.count && submitted < batchLimit {
                if try core.write(pending[pendingIndex]) == .full { break }
                pendingIndex += 1
                submitted += 1
            }
            if pendingIndex == pending.count {
                pending.removeAll(keepingCapacity: false)
                pendingIndex = 0
                requestRead()
            } else if submitted == batchLimit {
                schedulePump()
            }
            var output: [Data] = []
            var families: [Int32] = []
            while output.count < batchLimit, let packet = try core.read() {
                guard let family = family(of: packet) else { throw PacketEngineError.invalidPacket }
                output.append(packet)
                families.append(family)
            }
            if !output.isEmpty && !flow.writePackets(output, families: families) {
                throw PacketEngineError.outputRejected
            }
            if output.count == batchLimit { schedulePump() }
        } catch { fail(error) }
    }

    private func schedulePump() {
        guard !pumpScheduled, let token = generation else { return }
        pumpScheduled = true
        queue.async { [weak self] in
            guard let self, self.generation == token else { return }
            self.pumpScheduled = false
            self.pump()
        }
    }

    private func family(of packet: Data) -> Int32? {
        guard packet.count <= 65_535, let first = packet.first else { return nil }
        switch first >> 4 {
        case 4 where packet.count >= 20: return Int32(AF_INET)
        case 6 where packet.count >= 40: return Int32(AF_INET6)
        default: return nil
        }
    }

    private func fail(_ error: Error) {
        let startup = startCompletion
        startCompletion = nil
        let wasStarting = state == .starting
        _ = cleanup()
        if wasStarting {
            if let startup { deliver { startup(.failure(error)) } }
        } else {
            deliver { self.onFailure(error) }
        }
    }

    private func cleanup() -> Result<Void, Error> {
        timer?.cancel()
        timer = nil
        generation = nil
        flow = nil
        reading = false
        pending.removeAll(keepingCapacity: false)
        pendingIndex = 0
        pumpScheduled = false
        state = .idle
        startupKeepAlive = nil
        guard let previous = core else { return .success(()) }
        core = nil
        previous.shutdown()
        do { try previous.destroy(); return .success(()) }
        catch { return .failure(error) }
    }

    private func deliver(_ callback: @escaping () -> Void) {
        callbackQueue.async(execute: callback)
    }
}
