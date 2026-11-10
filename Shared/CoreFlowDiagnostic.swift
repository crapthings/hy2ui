import Foundation
import Darwin

/// Identifies the bounded flow-error fields accepted from the Rust worker.
public struct CoreFlowDiagnostic: Codable, Equatable, Sendable {
    /// Restricts transport names to protocols supported by the local TUN.
    public enum ProtocolName: String, Codable, Sendable { case tcp, udp }
    /// Distinguishes an explicitly direct socket from a Hy2 proxy stream.
    public enum Route: String, Codable, Sendable { case direct, proxy }
    /// Identifies which operation failed without forwarding arbitrary upstream text.
    public enum Phase: String, Codable, Sendable {
        case connect, session, transfer, send, receive
        public var title: String {
            switch self {
            case .connect: "目标建连失败"; case .session: "会话建立失败"; case .transfer: "数据传输失败"
            case .send: "发送失败"; case .receive: "接收失败"
            }
        }
    }
    /// Maps known failure categories to localizable explanations without copying server messages.
    public enum Reason: String, Codable, Sendable {
        case timeout, refused, network_unreachable, host_unreachable, dns, reset, broken_pipe, unexpected_eof
        case ipv4_unavailable, ipv6_unavailable, address_unavailable, permission, quic_timeout, quic_connect, authentication, protocol_error, io, udp_disabled, session_closed, datagram_too_large, closed
        public var title: String {
            switch self {
            case .timeout: "操作超时"; case .refused: "目标拒绝连接"; case .network_unreachable: "网络不可达"
            case .host_unreachable: "目标主机不可达"; case .dns: "无法解析目标地址"; case .reset: "连接被重置"
            case .broken_pipe: "对端已关闭写入通道"; case .unexpected_eof: "连接提前结束"; case .permission: "操作被拒绝"
            case .ipv4_unavailable: "本地网络没有 IPv4 直连出口"; case .ipv6_unavailable: "本地网络没有 IPv6 直连出口"
            case .address_unavailable: "本地地址不可用"; case .quic_timeout: "QUIC 连接建立超时"
            case .quic_connect: "QUIC 连接建立失败"; case .authentication: "服务器认证失败"; case .protocol_error: "协议错误"
            case .io: "I/O 错误，核心未提供可识别的原因"; case .udp_disabled: "服务器未启用 UDP 转发"
            case .session_closed: "UDP 会话已关闭"; case .datagram_too_large: "UDP 数据报过大"; case .closed: "传输连接已关闭"
            }
        }
    }
    public let transport: ProtocolName
    public let route: Route
    public let phase: Phase
    public let target: String
    public let reason: Reason
    public let code: Int
    public let suppressed: UInt64
    private static let prefix = "HY2UI_FLOW_DIAGNOSTIC "

    public static func parse(_ line: String) -> Self? {
        guard line.utf8.count <= 512 else { return nil }
        let fields = line.split(separator: " ", omittingEmptySubsequences: false)
        guard (fields.count == 7 || fields.count == 12), fields[0] == "HY2UI_FLOW_ERROR",
              let transport = ProtocolName(rawValue: String(fields[1])), let route = Route(rawValue: String(fields[2])),
              let phase = Phase(rawValue: String(fields[3])), let reason = Reason(rawValue: String(fields[5])),
              let code = Int(fields[6]), (0...65535).contains(code), validTarget(String(fields[4])) else { return nil }
        var suppressed: UInt64 = 0
        if fields.count == 12 {
            guard fields[7].hasPrefix("("), let count = UInt64(fields[7].dropFirst()), count <= 1_000_000_000,
                  fields[8...11].map(String.init) == ["additional", "TUN", "errors", "suppressed)"] else { return nil }
            suppressed = count
        }
        return Self(transport: transport, route: route, phase: phase, target: String(fields[4]), reason: reason, code: code, suppressed: suppressed)
    }

    public var logMessage: String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return Self.prefix + String(decoding: data, as: UTF8.self)
    }

    public static func fromLogMessage(_ text: String) -> Self? {
        guard text.hasPrefix(prefix), text.utf8.count <= 1024,
              let value = try? JSONDecoder().decode(Self.self, from: Data(text.dropFirst(prefix.count).utf8)),
              validTarget(value.target), (0...65535).contains(value.code), value.suppressed <= 1_000_000_000 else { return nil }
        return value
    }

    public func render(detailed: Bool, localized: (String) -> String) -> String {
        let summary = "\(transport.rawValue.uppercased()) · \(localized(route == .direct ? "直连" : "代理")) · \(localized(phase.title))"
        guard detailed else { return summary }
        var details = "\(localized("目标"))：\(target) · \(localized("原因"))：\(localized(reason.title))"
        if code != 0 { details += " · \(localized("错误代码"))：\(code)" }
        if suppressed != 0 { details += " · \(localized("已合并的其他错误"))：\(suppressed)" }
        if isSyntheticTarget { details += "\n  " + localized("目标位于保留测试网段，可能残留其他代理的 DNS 缓存。") }
        return summary + "\n  " + details
    }

    public var isSyntheticTarget: Bool {
        let octets = target.split(separator: ":").first?.split(separator: ".").compactMap { UInt8($0) } ?? []
        return octets.count == 4 && octets[0] == 198 && (octets[1] == 18 || octets[1] == 19)
    }

    private static func validTarget(_ value: String) -> Bool {
        guard value.utf8.count <= 64 else { return false }
        let host: String, port: Substring, family: Int32
        if value.hasPrefix("["), let close = value.firstIndex(of: "]"), value[value.index(after: close)...].hasPrefix(":") {
            host = String(value[value.index(after: value.startIndex)..<close]); port = value[value.index(close, offsetBy: 2)...]; family = AF_INET6
        } else {
            let parts = value.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2 else { return false }
            host = String(parts[0]); port = parts[1]; family = AF_INET
        }
        var address = in6_addr()
        return UInt16(port).map { $0 > 0 } == true && host.withCString { inet_pton(family, $0, &address) == 1 }
    }
}
