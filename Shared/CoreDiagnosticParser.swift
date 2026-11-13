import Foundation
import Darwin

/// Parses bounded core output into ordered safe observations while preserving fragmented line boundaries.
public struct CoreDiagnosticParser: Sendable {
    private var line: [UInt8] = []
    private var discardingLine = false
    private var pending: [LocalTunCoreEvent] = []
    private var flowDiagnostics: [CoreFlowDiagnostic] = []
    private var telemetry: [CoreTelemetry] = []
    public private(set) var coreReason: String?
    public private(set) var coreFailure: LocalTunCoreFailure?
    public private(set) var startupFailure: LocalTunFailureCode?
    private var connectionSeen = false
    private var tunnelSeen = false
    private let requiresConnection: Bool
    public var serverAuthenticated: Bool { connectionSeen }
    public var nativeInterfaceReady: Bool { tunnelSeen }
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

    /// Extracts only fixed local-operation labels and numeric OS errors, never arbitrary stderr.
    private static func safeLocalReason(_ text: String, category: LocalTunCoreFailure) -> String? {
        guard [.tunRoutes, .tunDevice, .tunParent, .tunIdentity, .tunRouteInspection].contains(category) else { return nil }
        var parts: [String] = []
        let operations = [
            ("error: cannot acquire TUN route journal: ", "建立或锁定路由恢复记录"),
            ("error: failed to add TUN route ", "向内核添加路由"),
            ("error: failed to open route manager: ", "打开系统路由管理器"),
            ("error: failed to inspect system routes: ", "读取系统路由表"),
            ("error: failed to create TUN interface: ", "创建或配置虚拟网卡")
        ]
        if let operation = operations.first(where: { text.hasPrefix($0.0) }) { parts.append("操作：" + operation.1) }
        let routePrefix = "error: failed to add TUN route Route { destination: "
        if category == .tunRoutes, text.hasPrefix(routePrefix),
           let end = text.range(of: " }:", range: text.index(text.startIndex, offsetBy: routePrefix.count)..<text.endIndex) {
            let fields = text.dropFirst(routePrefix.count).prefix(upTo: end.lowerBound).components(separatedBy: ", ")
            if let first = fields.first, first.contains("/"), let destination = try? IPNetwork(first) {
                parts.append("目的网段：" + destination.cidr)
            }
            for field in fields.dropFirst() {
                if field.hasPrefix("gateway: ") {
                    let value = String(field.dropFirst(9))
                    if value == "None" { parts.append("网关：接口直连") }
                    else if !value.contains("/"), let gateway = try? IPNetwork(value) { parts.append("网关：" + gateway.address) }
                } else if field.hasPrefix("if_index: "), let index = UInt32(field.dropFirst(10)), index > 0 {
                    parts.append("接口索引：\(index)")
                }
            }
        }
        let reasons = [
            ("existing route conflicts with the required forwarding identity", "已有路由的出口与所需出口不同，或存在多个同键条目，不能安全借用"),
            ("route already exists or journal cannot accept another receipt", "路由已存在，或恢复记录无法接受新条目"),
            ("added route identity could not be verified", "添加后的路由身份与预期不一致"),
            ("route journal is owned by an active client or recovery", "恢复记录被其他客户端或恢复任务锁定"),
            ("journal requires an absolute path without symlink parents", "恢复记录路径不是无符号链接的绝对路径"),
            ("journal ancestor ownership or permissions are unsafe", "恢复记录上级目录的属主或权限不符合要求"),
            ("journal directory ownership or permissions are unsafe", "恢复记录目录的属主或权限不符合要求"),
            ("route journal file ownership, size or permissions are unsafe", "恢复记录文件的属主、大小或权限不符合要求"),
            ("route receipt has noncanonical destination", "生成的路由目的网段不是规范网络地址"),
            ("route has no interface", "待记录路由缺少接口索引"),
            ("invalid route journal receipt", "生成的路由恢复条目无效"),
            ("cannot identify macOS boot session", "无法读取系统启动会话标识"),
            ("TUN session parent exited or changed identity", "后台父进程已经退出或身份发生变化")
        ]
        let suffix = " [" + category.rawValue + "]"
        if let reason = reasons.first(where: { text.hasSuffix($0.0 + suffix) }) { parts.append("原因：" + reason.1) }
        if let marker = text.range(of: "(os error ", options: .backwards) {
            let tail = text[marker.upperBound...]
            if let end = tail.firstIndex(of: ")"), let number = Int(tail[..<end]), (1...4095).contains(number) {
                parts.append("系统错误 errno=\(number)（\(String(cString: strerror(Int32(number))))）")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "；")
    }

    private mutating func observe(_ text: String) {
        if text.hasPrefix("error: "), text.hasSuffix("]"),
           let marker = text.range(of: " [", options: .backwards),
           let failure = LocalTunCoreFailure(rawValue: String(text[marker.upperBound..<text.index(before: text.endIndex)])) {
            coreFailure = failure
            coreReason = Self.safeLocalReason(text, category: failure)
            startupFailure = failure == .captureConflict ? .captureConflict : .startupFailed
            return
        }
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
