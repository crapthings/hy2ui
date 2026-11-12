import Foundation

/// Parses bounded core output into ordered safe observations while preserving fragmented line boundaries.
public struct CoreDiagnosticParser: Sendable {
    private var line: [UInt8] = []
    private var discardingLine = false
    private var pending: [LocalTunCoreEvent] = []
    private var flowDiagnostics: [CoreFlowDiagnostic] = []
    private var telemetry: [CoreTelemetry] = []
    private var connectionSeen = false
    private var tunnelSeen = false
    private let requiresConnection: Bool
    public var ready: Bool { tunnelSeen && (!requiresConnection || connectionSeen) }
    public init(requiresConnection: Bool = true) { self.requiresConnection = requiresConnection }

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

    public mutating func drainTelemetry() -> [CoreTelemetry] {
        defer { telemetry.removeAll(keepingCapacity: true) }
        return telemetry
    }

    public mutating func drainFlowDiagnostics() -> [CoreFlowDiagnostic] {
        defer { flowDiagnostics.removeAll(keepingCapacity: true) }
        return flowDiagnostics
    }

    private static func hasSyntheticTarget(_ text: String) -> Bool {
        guard let arrow = text.range(of: " -> "),
              let failure = text.range(of: " connect failed: ", range: arrow.upperBound..<text.endIndex) else { return false }
        let endpoint = text[arrow.upperBound..<failure.lowerBound]
        let parts = endpoint.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let port = UInt16(parts[1]), port > 0 else { return false }
        let octets = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        let address = octets.compactMap { UInt8($0) }
        return address.count == 4 && address[0] == 198 && (address[1] == 18 || address[1] == 19)
    }

    private mutating func observe(_ text: String) {
        if let sample = CoreTelemetry.parse(text) {
            if telemetry.count == 8 { telemetry.removeFirst() }
            telemetry.append(sample)
            return
        }
        if let diagnostic = CoreFlowDiagnostic.parse(text) {
            if flowDiagnostics.count == 32 { flowDiagnostics.removeFirst() }
            flowDiagnostics.append(diagnostic)
            return
        }
        let event: LocalTunCoreEvent?
        if text.hasPrefix("HY2UI_TCP_ERROR ") {
            switch text.split(separator: " ").dropFirst().first {
            case "connect_timeout": event = .tcpConnectTimedOut
            case "reset": event = .tcpReset
            case "broken_pipe": event = .tcpBrokenPipe
            case "transfer_timeout": event = .tcpTransferTimedOut
            case "unexpected_eof": event = .tcpUnexpectedEOF
            case "capacity": event = .tcpCapacity
            case "transfer_io": event = .tcpTransferFailed
            default: event = nil
            }
        } else if text == "HY2UI_ROUTE_DIRECT tcp" || text == "HY2UI_ROUTE_DIRECT udp" {
            event = .directFlow
        } else if text.hasPrefix("connected to ") {
            connectionSeen = true
            event = .connected
        } else if text.hasPrefix("TUN proxy listening on interface ") {
            tunnelSeen = true
            event = nil
        } else if text.hasPrefix("QUIC disconnected: ") {
            connectionSeen = false
            event = .disconnected
        } else if text.hasPrefix("TUN TCP "), text.contains(" connect failed: ") {
            event = Self.hasSyntheticTarget(text) ? .tcpSyntheticTargetFailed : .tcpConnectFailed
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
