import Foundation

/// Parses bounded core output into ordered safe observations while preserving fragmented line boundaries.
public struct CoreDiagnosticParser: Sendable {
    private var line: [UInt8] = []
    private var discardingLine = false
    private var pending: [LocalTunCoreEvent] = []
    private var connectionSeen = false
    private var tunnelSeen = false
    public var ready: Bool { connectionSeen && tunnelSeen }
    public init() {}

    public mutating func consume(_ bytes: Data) {
        for byte in bytes {
            if byte == 10 {
                if !discardingLine { observe(String(decoding: line, as: UTF8.self)) }
                line.removeAll(keepingCapacity: true)
                discardingLine = false
            } else if !discardingLine {
                if line.count < 8192 { line.append(byte) }
                else { line.removeAll(keepingCapacity: true); discardingLine = true }
            }
        }
    }

    public mutating func drain() -> [LocalTunCoreEvent] {
        let result = pending
        pending.removeAll(keepingCapacity: true)
        return result
    }

    private mutating func observe(_ text: String) {
        let event: LocalTunCoreEvent?
        if text.hasPrefix("connected to ") {
            connectionSeen = true
            event = .connected
        } else if text.hasPrefix("TUN proxy listening on interface ") {
            tunnelSeen = true
            event = nil
        } else if text.hasPrefix("QUIC disconnected: ") {
            connectionSeen = false
            event = .disconnected
        } else if text.hasPrefix("TUN TCP "), text.contains(" connect failed: ") {
            event = .tcpConnectFailed
        } else if text.hasPrefix("TUN TCP "), text.contains(" transfer failed: ") {
            event = .tcpTransferFailed
        } else if text.hasPrefix("TUN UDP "), text.contains(" session failed: ") {
            event = .udpSessionFailed
        } else if text.hasPrefix("TUN UDP "), text.contains(" send failed: ") {
            event = .udpSendFailed
        } else if text.hasPrefix("TUN UDP "), text.contains(" receive failed: ") {
            event = .udpReceiveFailed
        } else { event = nil }
        guard let event, pending.last != event else { return }
        if pending.count == 32 { pending.removeFirst() }
        pending.append(event)
    }
}
