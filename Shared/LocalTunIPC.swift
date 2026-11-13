import Foundation
import Darwin

/// Defines fixed privileged-helper locations and the bounded local wire format.
public enum LocalTunWire {
    public static let installationDirectory = "/Library/PrivilegedHelperTools/dev.hy2ui"
    public static let socketPath = installationDirectory + "/control.sock"
    public static let workerPath = installationDirectory + "/hy2-tun-worker"
    public static let routeJournalPath = installationDirectory + "/tun-routes-v1.json"
    public static let directRoutesJournalPath = installationDirectory + "/direct-routes.json"
    public static let journalPath = installationDirectory + "/dns-recovery.plist"
    public static let maxMessageBytes = 65_536
}

/// Carries bounded CLI TUN settings while retaining decodable legacy worker fields.
public struct LocalTunConfiguration: Codable, Equatable, Sendable {
    public let host: String
    public let port: Int
    public let serverName: String
    public let password: String
    public let obfuscationPassword: String
    public let mtu: Int
    public let dns: [String]
    public let directProcesses: [String]?
    public let bypassLocalNetworks: Bool?
    public let addressRules: [String]?
    public let finalDirect: Bool?

    public init(host: String, port: Int, serverName: String = "", password: String,
                obfuscationPassword: String = "", mtu: Int = 1400,
                dns: [String] = ["1.1.1.1", "2606:4700:4700::1111"], directProcesses: [String]? = nil, bypassLocalNetworks: Bool? = nil, addressRules: [String]? = nil, finalDirect: Bool? = nil) {
        self.host = host
        self.port = port
        self.serverName = serverName
        self.password = password
        self.obfuscationPassword = obfuscationPassword
        self.mtu = mtu
        self.dns = dns
        self.directProcesses = directProcesses
        self.bypassLocalNetworks = bypassLocalNetworks
        self.addressRules = addressRules
        self.finalDirect = finalDirect
    }

    public func validate() throws {
        if let rules = addressRules {
            guard rules.count <= 128 else { throw LocalTunProtocolError.invalidConfiguration }
            for rule in rules {
                let parts = rule.split(separator: ",", omittingEmptySubsequences: false)
                guard parts.count == 2, ["direct", "proxy"].contains(String(parts[0])), (try? IPNetwork(String(parts[1]))) != nil else { throw LocalTunProtocolError.invalidConfiguration }
            }
        }
        if let patterns = directProcesses {
            guard patterns.count <= 64, patterns.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 && !$0.contains(",") && !$0.contains("\\") && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines) && (!$0.contains("/") || $0.hasPrefix("/")) && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }) else {
                throw LocalTunProtocolError.invalidConfiguration
            }
        }

        guard !host.isEmpty, host.utf8.count <= 253,
              host == host.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.contains(where: { $0.isWhitespace || "/@[]?#\\".contains($0) }),
              !host.contains(":") || Self.isIP(host, family: AF_INET6),
              !host.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              (1...65535).contains(port), !password.isEmpty,
              password.utf8.count <= 4096, obfuscationPassword.utf8.count <= 4096,
              serverName.utf8.count <= 253,
              !serverName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !serverName.contains(where: { $0.isWhitespace || "/:@\\".contains($0) }),
              (1280...1500).contains(mtu), (1...8).contains(dns.count),
              dns.allSatisfy({ Self.isIP($0, family: AF_INET) || Self.isIP($0, family: AF_INET6) }) else {
            throw LocalTunProtocolError.invalidConfiguration
        }
    }

    private static func isIP(_ value: String, family: Int32) -> Bool {
        var storage = in6_addr()
        return value.withCString { inet_pton(family, $0, &storage) == 1 }
    }
}

/// Identifies the limited operations accepted by the local helper.
public enum LocalTunCommand: String, Codable, Sendable {
    case start, stop, status
}

/// Requests one bounded helper operation without accepting executable paths or raw core configuration.
public struct LocalTunRequest: Codable, Sendable {
    public let command: LocalTunCommand
    public let configuration: LocalTunConfiguration?

    public init(command: LocalTunCommand, configuration: LocalTunConfiguration? = nil) {
        self.command = command
        self.configuration = configuration
    }
}

/// Identifies the lifecycle events emitted by a privileged helper session.
public enum LocalTunEventKind: String, Codable, Sendable {
    case ready, stopped, error, log
}

/// Carries bounded QUIC byte counters and path RTT for one core connection.
public struct CoreTelemetry: Codable, Equatable, Sendable {
    public let connection: UInt64
    public let upload: UInt64
    public let download: UInt64
    public let rttMicros: UInt64
    public let elapsedMicros: UInt64?

    public init(connection: UInt64, upload: UInt64, download: UInt64, rttMicros: UInt64, elapsedMicros: UInt64? = nil) {
        self.connection = connection; self.upload = upload; self.download = download; self.rttMicros = rttMicros; self.elapsedMicros = elapsedMicros
    }

    public static func parse(_ line: String) -> Self? {
        guard line.utf8.count <= 256 else { return nil }
        let fields = line.split(separator: " ", omittingEmptySubsequences: false)
        guard (fields.count == 5 || fields.count == 6), fields[0] == "HY2UI_METRICS" else { return nil }
        let numbers = fields.dropFirst().compactMap { field -> UInt64? in
            guard !field.isEmpty, field.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
            return UInt64(field)
        }
        guard numbers.count == fields.count - 1, numbers[0] > 0, numbers[3] <= 600_000_000 else { return nil }
        return Self(connection: numbers[0], upload: numbers[1], download: numbers[2], rttMicros: numbers[3], elapsedMicros: numbers.count == 5 ? numbers[4] : nil)
    }
}

/// Associates a metric sample with a worker generation to reject cross-session counter reuse.
public struct CoreTelemetryObservation: Sendable {
    public let session: UUID
    public let metrics: CoreTelemetry
    public init(session: UUID, metrics: CoreTelemetry) { self.session = session; self.metrics = metrics }
}

/// Identifies a process by PID and birth time rather than a reusable PID alone.
public struct LocalTunProcessIdentity: Codable, Equatable, Sendable {
    public let pid: UInt32
    public let startSeconds: UInt64
    public let startMicroseconds: UInt64
    private enum CodingKeys: String, CodingKey { case pid; case startSeconds = "start_seconds"; case startMicroseconds = "start_microseconds" }
    public init(pid: UInt32, startSeconds: UInt64, startMicroseconds: UInt64) {
        self.pid = pid; self.startSeconds = startSeconds; self.startMicroseconds = startMicroseconds
    }
    public var isValid: Bool { pid > 1 && pid <= UInt32(Int32.max) && startSeconds > 0 && startMicroseconds < 1_000_000 }
    public var isCurrent: Bool {
        guard isValid else { return false }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        return proc_pidinfo(Int32(pid), PROC_PIDTBSDINFO, 0, &info, size) == size
            && info.pbi_start_tvsec == startSeconds && info.pbi_start_tvusec == startMicroseconds
    }
}

/// Carries the kernel interface name and index returned for the owned TUN device.
public struct LocalTunInterfaceIdentity: Codable, Equatable, Sendable {
    public let name: String
    public let index: UInt32
    public init(name: String, index: UInt32) { self.name = name; self.index = index }
    public var isValid: Bool {
        let number = name.dropFirst(4)
        return name.hasPrefix("utun") && name.utf8.count <= 15 && !number.isEmpty
            && number.utf8.allSatisfy { (48...57).contains($0) } && index > 0
    }
    public var isCurrent: Bool { isValid && name.withCString { if_nametoindex($0) } == index }
}

/// Associates the Hy2UI session token with its actual interface and original worker/helper identities.
public struct LocalTunInterfaceSession: Codable, Equatable, Sendable {
    public let id: String
    public let owner: String
    public let process: LocalTunProcessIdentity
    public let interface: LocalTunInterfaceIdentity
    public let parent: LocalTunProcessIdentity?
    public init(id: String, owner: String = "dev.hy2ui", process: LocalTunProcessIdentity, interface: LocalTunInterfaceIdentity, parent: LocalTunProcessIdentity? = nil) {
        self.id = id; self.owner = owner; self.process = process; self.interface = interface; self.parent = parent
    }
    public func validate() throws {
        guard UUID(uuidString: id) != nil, owner == "dev.hy2ui", process.isValid, interface.isValid,
              parent.map(\.isValid) ?? true else { throw LocalTunProtocolError.invalidMessage }
    }
}

/// Reports a helper lifecycle result without including credentials or raw worker output.
public struct LocalTunEvent: Codable, Sendable {
    public let kind: LocalTunEventKind
    public let message: String?
    public let failure: LocalTunFailure?
    public let coreEvent: LocalTunCoreEvent?
    public let metrics: CoreTelemetry?
    public let interfaceSession: LocalTunInterfaceSession?

    public init(kind: LocalTunEventKind, message: String? = nil, failure: LocalTunFailure? = nil, coreEvent: LocalTunCoreEvent? = nil, metrics: CoreTelemetry? = nil, interfaceSession: LocalTunInterfaceSession? = nil) {
        self.kind = kind
        self.message = message
        self.failure = failure
        self.coreEvent = coreEvent
        self.metrics = metrics
        self.interfaceSession = interfaceSession
    }
}

/// Describes an invalid or oversized request without revealing supplied values.
public enum LocalTunProtocolError: LocalizedError {
    case invalidConfiguration, invalidMessage, messageTooLarge
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "本地增强模式配置无效。"
        case .invalidMessage: "本地增强模式请求无效。"
        case .messageTooLarge: "本地增强模式请求超过大小限制。"
        }
    }
}

/// Serializes newline-delimited helper messages while enforcing one shared size limit.
public enum LocalTunMessageCodec {
    public static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        var data = try JSONEncoder().encode(value)
        guard data.count < LocalTunWire.maxMessageBytes else { throw LocalTunProtocolError.messageTooLarge }
        data.append(10)
        return data
    }

    public static func decodeRequest(_ data: Data) throws -> LocalTunRequest {
        guard data.count <= LocalTunWire.maxMessageBytes else { throw LocalTunProtocolError.messageTooLarge }
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any], Set(dictionary.keys).isSubset(of: ["command", "configuration"]) else {
            throw LocalTunProtocolError.invalidMessage
        }
        if let configuration = dictionary["configuration"] as? [String: Any] {
            let allowed: Set<String> = ["host", "port", "serverName", "password", "obfuscationPassword", "mtu", "dns", "directProcesses", "bypassLocalNetworks", "addressRules", "finalDirect"]
            guard Set(configuration.keys).isSubset(of: allowed) else { throw LocalTunProtocolError.invalidMessage }
        }
        let request = try JSONDecoder().decode(LocalTunRequest.self, from: data)
        if request.command == .start {
            guard let configuration = request.configuration else { throw LocalTunProtocolError.invalidConfiguration }
            try configuration.validate()
        } else if request.configuration != nil {
            throw LocalTunProtocolError.invalidMessage
        }
        return request
    }
}

/// Names safe failure categories without forwarding worker stderr or caller-provided values.
public enum LocalTunFailureCode: String, Codable, Sendable {
    case startupFailed, startupTimedOut, workerExited, dnsFailed, recoveryFailed, captureConflict, invalidRequest, permissions, cancelled, unknown
    public var message: String {
        switch self {
        case .startupFailed: "TUN 核心启动失败，请检查后台日志。"
        case .captureConflict: "存在其他 VPN／增强模式接管，或出口路由不明确。请先关闭其他增强模式后重试。"
        case .startupTimedOut: "TUN 核心启动超时。"
        case .workerExited: "TUN 核心意外退出，请先恢复网络设置。"
        case .dnsFailed: "后台无法设置或恢复 DNS。"
        case .recoveryFailed: "后台网络恢复失败，请重试清理。"
        case .invalidRequest: "后台收到无效请求。"
        case .permissions: "后台安装权限校验失败，请修复后台。"
        case .cancelled: "后台操作已取消。"
        case .unknown: "后台操作失败，网络恢复状态尚未确认。"
        }
    }
}

/// Maps stable core error identifiers to safe diagnostic guidance without retaining stderr.
public enum LocalTunCoreFailure: String, Codable, Sendable, CaseIterable {
    case runtimeFailure = "runtime_failure", captureConflict = "capture_conflict"
    case tunParent = "tun_parent", tunDevice = "tun_device", tunIdentity = "tun_identity"
    case tunRoutes = "tun_routes", tunRouteInspection = "tun_route_inspection"
    case tunAddressConflict = "tun_address_conflict"
    case listenerBind = "listener_bind", tlsRead = "tls_read", tlsInvalid = "tls_invalid"
    case connectionFailed = "connection_failed", authenticationRejected = "authentication_rejected"
    case configurationRead = "configuration_read", configurationParse = "configuration_parse"
    case configurationTooLarge = "configuration_too_large", configurationInvalid = "configuration_invalid"

    public var guidance: String {
        switch self {
        case .tunParent: "后台父进程身份校验或监控失败，尚不能据此认定网卡权限不足。"
        case .tunDevice: "创建或配置 utun 接口失败，包括地址、MTU 和启用接口；需检查系统返回的错误。"
        case .tunIdentity: "网卡已创建，但读取接口或进程身份失败；未确认启动成功。"
        case .tunAddressConflict: "虚拟网卡地址段与已有路由冲突，尚未创建接口；需要选择未占用的网卡地址段。"
        case .tunRoutes: "安装 TUN 路由或写入恢复记录失败，请先完成网络恢复后重试。"
        case .tunRouteInspection: "创建网卡前读取系统路由失败，尚未进入网卡创建步骤。"
        case .runtimeFailure: "核心运行阶段失败；该分类尚不能区分父进程校验、网卡创建或路由操作，不能据此认定权限不足。"
        case .captureConflict: "路由预检失败：检测到其他隧道接管或出口路由不明确，请检查当前路由。"
        case .listenerBind: "本地监听绑定失败，请检查监听地址及端口占用。"
        case .tlsRead: "TLS 文件读取失败，请检查证书文件路径和后台的读取权限。"
        case .tlsInvalid: "TLS 配置无效，请检查证书、密钥及 TLS 设置。"
        case .connectionFailed: "服务器连接建立失败，请检查 UDP 可达性、TLS 名称及服务端日志；这不等于网卡权限不足。"
        case .authenticationRejected: "服务器拒绝认证，请检查服务器地址、密码和服务端认证配置。"
        case .configurationRead: "核心无法读取配置，请检查后台向核心传递配置的管道。"
        case .configurationParse: "核心无法解析配置，请核对后台生成的配置与核心版本是否兼容。"
        case .configurationTooLarge: "配置超过核心大小限制，请检查后台生成的配置。"
        case .configurationInvalid: "配置校验失败，请核对当前核心支持的 TUN 参数。"
        }
    }
}

/// Carries an allowlisted error category and numeric process exit details across the helper boundary.
public struct LocalTunFailure: Codable, LocalizedError, Sendable {
    public let code: LocalTunFailureCode
    public let coreReason: String?
    public let coreFailure: LocalTunCoreFailure?
    public let exitStatus: Int32?
    public let terminatedBySignal: Bool
    public init(_ code: LocalTunFailureCode, exitStatus: Int32? = nil, terminatedBySignal: Bool = false, coreFailure: LocalTunCoreFailure? = nil, coreReason: String? = nil) {
        self.code = code
        self.coreFailure = coreFailure
        self.coreReason = coreReason
        self.exitStatus = exitStatus
        self.terminatedBySignal = terminatedBySignal
    }
    public var errorDescription: String? { code.message }
    public var diagnostic: String {
        let summary = "\(code.message) [code=\(code.rawValue), exit=\(exitStatus.map(String.init) ?? "unknown"), signal=\(terminatedBySignal)]"
        guard let coreFailure else { return summary }
        return summary + "\n  core=\(coreFailure.rawValue)：\(coreFailure.guidance)" + (coreReason.map { "\n  " + $0 } ?? "")
    }
}

/// Serializes only safe failure metadata for the privileged daemon's persistent diagnostic log.
public struct LocalTunDiagnosticRecord: Codable, Sendable {
    public let timestamp: Date
    public let failure: LocalTunFailure
    public init(failure: LocalTunFailure, timestamp: Date = Date()) {
        self.timestamp = timestamp
        self.failure = failure
    }
}

/// Names allowlisted core observations without carrying upstream error text or destination addresses.
public enum LocalTunCoreEvent: String, Codable, Sendable {
    case tcpConnectTimedOut, tcpReset, tcpBrokenPipe, tcpTransferTimedOut, tcpUnexpectedEOF, tcpCapacity
    case connected, disconnected, directFlow, tcpConnectFailed, tcpSyntheticTargetFailed, tcpTransferFailed, udpSessionFailed, udpSendFailed, udpReceiveFailed
    public var message: String {
        switch self {
        case .directFlow: "应用直连规则已命中。"
        case .connected: "核心连接已建立，已有连接可能需要重试。"
        case .disconnected: "核心连接已中断，将在新请求到来时尝试连接。"
        case .tcpConnectFailed: "核心报告 TCP 目标建连失败。"
        case .tcpSyntheticTargetFailed: "TCP 目标位于 198.18.0.0/15，可能残留其他代理的 DNS 缓存。"
        case .tcpConnectTimedOut: "TCP 目标建连超时。"
        case .tcpReset: "TCP 连接被重置。"
        case .tcpBrokenPipe: "TCP 对端已关闭写入通道。"
        case .tcpTransferTimedOut: "TCP 数据传输超时。"
        case .tcpUnexpectedEOF: "TCP 连接提前结束。"
        case .tcpCapacity: "TCP 并发连接已达上限，已拒绝新连接。"
        case .tcpTransferFailed: "核心报告 TCP 数据传输失败。"
        case .udpSessionFailed: "核心报告 UDP 会话建立失败。"
        case .udpSendFailed: "核心报告 UDP 数据发送失败。"
        case .udpReceiveFailed: "核心报告 UDP 数据接收失败。"
        }
    }
}
