import Foundation
import Darwin

/// Reports a failed assertion from the loopback Swift-to-Rust adapter integration test.
enum AdapterIntegrationFailure: Error { case failed(String) }

/// Asserts an invariant without exposing fixture configuration or credentials.
func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw AdapterIntegrationFailure.failed(message) }
}

/// Awaits an adapter completion while its callback queue remains free.
func awaitAdapter(_ operation: (@escaping (Result<Void, Error>) -> Void) -> Void) throws {
    let sem = DispatchSemaphore(value: 0)
    var result: Result<Void, Error>?
    operation { result = $0; sem.signal() }
    try expect(sem.wait(timeout: .now() + 12) == .success, "adapter completion timed out")
    try result!.get()
}

/// Stores a big-endian 16-bit value in a raw IP packet.
func put16(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt16) {
    bytes[offset] = UInt8(value >> 8)
    bytes[offset + 1] = UInt8(value & 0xff)
}

/// Stores a big-endian 32-bit value in a raw IP packet.
func put32(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt32) {
    put16(&bytes, offset, UInt16(value >> 16))
    put16(&bytes, offset + 2, UInt16(value & 0xffff))
}

/// Computes the Internet checksum needed for IPv4 and TCP fixture packets.
func checksum(_ bytes: [UInt8]) -> UInt16 {
    var sum: UInt32 = 0
    var index = 0
    while index < bytes.count {
        let low = index + 1 < bytes.count ? UInt32(bytes[index + 1]) : 0
        sum += (UInt32(bytes[index]) << 8) | low
        index += 2
    }
    while sum > 0xffff { sum = (sum & 0xffff) + (sum >> 16) }
    return ~UInt16(sum)
}

/// Creates an IPv4 header targeting a loopback echo server.
func ipv4(protocolNumber: UInt8, length: Int) -> [UInt8] {
    var packet = [UInt8](repeating: 0, count: length)
    packet[0] = 0x45
    put16(&packet, 2, UInt16(length))
    packet[8] = 64
    packet[9] = protocolNumber
    packet.replaceSubrange(12..<16, with: [10, 0, 0, 2])
    packet.replaceSubrange(16..<20, with: [127, 0, 0, 1])
    put16(&packet, 10, checksum(Array(packet[0..<20])))
    return packet
}

/// Creates a UDP packet for the local Hysteria test server to forward.
func udpPacket(port: UInt16, payload: [UInt8]) -> Data {
    var packet = ipv4(protocolNumber: 17, length: 28 + payload.count)
    put16(&packet, 20, 12345)
    put16(&packet, 22, port)
    put16(&packet, 24, UInt16(8 + payload.count))
    packet.replaceSubrange(28..<packet.count, with: payload)
    return Data(packet)
}

/// Creates a TCP segment with a valid IPv4 pseudo-header checksum.
func tcpPacket(port: UInt16, sequence: UInt32, acknowledgement: UInt32,
               flags: UInt8, payload: [UInt8] = []) -> Data {
    var packet = ipv4(protocolNumber: 6, length: 40 + payload.count)
    put16(&packet, 20, 12345)
    put16(&packet, 22, port)
    put32(&packet, 24, sequence)
    put32(&packet, 28, acknowledgement)
    packet[32] = 0x50
    packet[33] = flags
    put16(&packet, 34, 65535)
    packet.replaceSubrange(40..<packet.count, with: payload)
    var pseudo = Array(packet[12..<20]) + [0, 6, 0, 0]
    put16(&pseudo, 10, UInt16(20 + payload.count))
    pseudo += packet[20...]
    put16(&packet, 36, checksum(pseudo))
    return Data(packet)
}

/// Decodes a network-order 32-bit TCP sequence number.
func read32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    bytes[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
}

/// Mimics the system packet-flow callbacks while forwarding no real system traffic.
final class IntegrationPacketFlow: ExperimentalPacketFlow, @unchecked Sendable {
    typealias ReadCallback = ([Data], [Int32]) -> Void
    private let condition = NSCondition()
    private var callback: ReadCallback?
    private var output: [(Data, Int32)] = []

    func readPackets(completion: @escaping ReadCallback) {
        condition.lock(); defer { condition.unlock() }
        precondition(callback == nil, "only one read may be pending")
        callback = completion
        condition.broadcast()
    }
    func writePackets(_ packets: [Data], families: [Int32]) -> Bool {
        condition.lock(); defer { condition.unlock() }
        guard packets.count == families.count else { return false }
        output += zip(packets, families)
        condition.broadcast()
        return true
    }
    func takeCallback() throws -> ReadCallback {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(10)
        while callback == nil {
            guard condition.wait(until: deadline) else { throw AdapterIntegrationFailure.failed("system read timed out") }
        }
        let captured = callback!
        callback = nil
        return captured
    }
    func send(_ packet: Data) throws {
        try takeCallback()([packet], [Int32(AF_INET)])
    }
    func receive() throws -> [UInt8] {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(10)
        while output.isEmpty {
            guard condition.wait(until: deadline) else { throw AdapterIntegrationFailure.failed("packet output timed out") }
        }
        let (packet, family) = output.removeFirst()
        try expect(family == Int32(AF_INET), "unexpected output family")
        return Array(packet)
    }
}

/// Simulates successful system settings while a real Rust packet core handles loopback traffic.
final class IntegrationProviderSystem: ExperimentalProviderSystem {
    let flow = IntegrationPacketFlow()
    var packetFlow: ExperimentalPacketFlow { flow }
    private let lock = NSLock()
    private var installs = 0
    private var clears = 0
    private var cancellations = 0

    func installSettings(completion: @escaping (Result<Void, Error>) -> Void) {
        lock.lock(); installs += 1; lock.unlock()
        completion(.success(()))
    }
    func clearSettings(completion: @escaping (Result<Void, Error>) -> Void) {
        lock.lock(); clears += 1; lock.unlock()
        completion(.success(()))
    }
    func cancelTunnel(error: Error) { lock.lock(); cancellations += 1; lock.unlock() }
    func counts() -> (Int, Int, Int) { lock.lock(); defer { lock.unlock() }; return (installs, clears, cancellations) }
}

/// Exercises the actual Rust library through the Swift adapter using a loopback-only server.
@main enum PacketFlowAdapterIntegration {
    static func main() throws {
        try expect(CommandLine.arguments.count == 3, "expected fixture echo ports")
        guard let udpPort = UInt16(CommandLine.arguments[1]), let tcpPort = UInt16(CommandLine.arguments[2]) else {
            throw AdapterIntegrationFailure.failed("invalid fixture ports")
        }
        let config = FileHandle.standardInput.readDataToEndOfFile()
        guard var lazyConfig = try JSONSerialization.jsonObject(with: config) as? [String: Any] else {
            throw AdapterIntegrationFailure.failed("invalid fixture config")
        }
        lazyConfig["lazy"] = true
        let lazyData = try JSONSerialization.data(withJSONObject: lazyConfig)
        do {
            _ = try RustPacketCore(configuration: lazyData)
            throw AdapterIntegrationFailure.failed("lazy startup was accepted")
        } catch ExperimentalPacketError.unsupportedLazyConfiguration {
            // Capturing only after a connected core avoids lazy startup's readiness deadlock.
        }
        let failure = DispatchSemaphore(value: 0)
        let adapter = ExperimentalPacketAdapter(callbackQueue: DispatchQueue(label: "integration.callback"),
                                                coreFactory: { try RustPacketCore(configuration: $0) },
                                                onFailure: { _ in failure.signal() })
        let flow = IntegrationPacketFlow()
        try awaitAdapter { adapter.start(configuration: config, completion: $0) }
        try awaitAdapter { adapter.attach(flow: flow, completion: $0) }

        let udpPayload = Array("adapter-udp-through-rust".utf8)
        try flow.send(udpPacket(port: udpPort, payload: udpPayload))
        let udp = try flow.receive()
        try expect(udp.count >= 28 && udp[9] == 17, "invalid UDP output")
        let udpHeader = Int(udp[0] & 15) * 4
        try expect(udp.count >= udpHeader + 8, "truncated UDP header")
        try expect(Array(udp[(udpHeader + 8)...]) == udpPayload, "UDP payload mismatch")
        print("Swift packet adapter -> Rust -> UDP echo: OK")

        try flow.send(tcpPacket(port: tcpPort, sequence: 1, acknowledgement: 0, flags: 0x02))
        let syn = try flow.receive()
        try expect(syn.count >= 40, "truncated TCP SYN-ACK")
        let offset = Int(syn[0] & 15) * 4
        try expect(syn.count >= offset + 20 && syn[offset + 13] & 0x12 == 0x12, "invalid SYN-ACK")
        let ack = read32(syn, offset + 4) &+ 1
        try flow.send(tcpPacket(port: tcpPort, sequence: 2, acknowledgement: ack, flags: 0x10))
        let tcpPayload = Array("adapter-tcp-through-rust".utf8)
        try flow.send(tcpPacket(port: tcpPort, sequence: 2, acknowledgement: ack, flags: 0x18, payload: tcpPayload))
        var received: [UInt8] = []
        while received.count < tcpPayload.count {
            let reply = try flow.receive()
            try expect(reply.count >= 40, "truncated TCP reply")
            let ip = Int(reply[0] & 15) * 4
            try expect(reply.count >= ip + 20, "truncated TCP header")
            let tcp = Int(reply[ip + 12] >> 4) * 4
            try expect(reply.count >= ip + tcp, "invalid TCP header")
            received += reply[(ip + tcp)...]
        }
        try expect(received == tcpPayload, "TCP payload mismatch")
        print("Swift packet adapter -> Rust -> TCP echo: OK")

        let stale = try flow.takeCallback()
        try awaitAdapter { adapter.stop(completion: $0) }
        stale([udpPacket(port: udpPort, payload: udpPayload)], [Int32(AF_INET)])
        try expect(failure.wait(timeout: .now() + 0.1) == .timedOut, "stopped adapter reported a failure")
        print("Swift adapter stop and stale system callback: OK")

        guard var invalid = try JSONSerialization.jsonObject(with: config) as? [String: Any] else {
            throw AdapterIntegrationFailure.failed("invalid fixture config")
        }
        invalid["auth"] = "deliberately-wrong"
        let invalidConfig = try JSONSerialization.data(withJSONObject: invalid)
        let failedAdapter = ExperimentalPacketAdapter(callbackQueue: DispatchQueue(label: "integration.failure"),
                                                      coreFactory: { try RustPacketCore(configuration: $0) },
                                                      onFailure: { _ in failure.signal() })
        let finished = DispatchSemaphore(value: 0)
        var failed = false
        failedAdapter.start(configuration: invalidConfig) { result in
            if case let .failure(error) = result, case .coreFailed = error as? ExperimentalPacketError { failed = true }
            finished.signal()
        }
        try expect(finished.wait(timeout: .now() + 12) == .success && failed, "authentication failure was not reported")
        try awaitAdapter { failedAdapter.stop(completion: $0) }
        print("Swift adapter authentication failure: OK")

        let providerSystem = IntegrationProviderSystem()
        let providerCallbacks = DispatchQueue(label: "integration.provider.callback")
        let cleanupFailure = DispatchSemaphore(value: 0)
        let coordinator = ExperimentalProviderCoordinator(
            system: providerSystem, callbackQueue: providerCallbacks,
            engineFactory: { failure in
                ExperimentalPacketAdapter(callbackQueue: providerCallbacks,
                                          coreFactory: { try RustPacketCore(configuration: $0) },
                                          onFailure: failure)
            }, onCleanupFailure: { _ in cleanupFailure.signal() }
        )
        try awaitAdapter { coordinator.start(configuration: config, completion: $0) }
        let providerPayload = Array("coordinator-udp-through-rust".utf8)
        try providerSystem.flow.send(udpPacket(port: udpPort, payload: providerPayload))
        let providerReply = try providerSystem.flow.receive()
        try expect(providerReply.count >= 28 && providerReply[9] == 17, "invalid coordinator UDP output")
        let providerHeader = Int(providerReply[0] & 15) * 4
        try expect(providerReply.count >= providerHeader + 8, "truncated coordinator UDP header")
        try expect(Array(providerReply[(providerHeader + 8)...]) == providerPayload, "coordinator UDP payload mismatch")
        try awaitAdapter { coordinator.stop(completion: $0) }
        let counts = providerSystem.counts()
        try expect(counts.0 == 1 && counts.1 == 1 && counts.2 == 0, "coordinator lifecycle did not cleanly finish")
        try expect(cleanupFailure.wait(timeout: .now() + 0.1) == .timedOut, "coordinator cleanup failed")
        print("Provider coordinator -> Swift adapter -> Rust -> UDP echo: OK")
    }
}
