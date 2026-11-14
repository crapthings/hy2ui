import Foundation
import Darwin

/// Selects the implementation that owns enhanced-mode interfaces, DNS, and routing.
public enum EnhancedBackend: String, Codable, CaseIterable, Sendable {
    case localTun, networkExtension
    public static var allCases: [EnhancedBackend] {
        #if HY2_NETWORK_EXTENSION
        [.localTun, .networkExtension]
        #else
        [.localTun]
        #endif
    }
    public var title: String { self == .localTun ? "兼容模式（本地 TUN）" : "Network Extension（开发者签名）" }
}

/// Stores the editable server and local networking settings for one connection profile.
public struct Profile: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var name = "我的服务器"
    public var host = ""
    public var port = 443
    public var serverName = ""
    public var systemProxyEnabled = true
    public var enhancedModeEnabled = false
    public var enhancedBackend = EnhancedBackend.localTun

    public var allowLAN = false
    public var httpPort = 18080
    public var socksPort = 11080
    public var mtu = 1400
    public var dns = ["1.1.1.1", "2606:4700:4700::1111"]
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case allowLAN, id, name, host, port, serverName, mode, systemProxyEnabled, enhancedModeEnabled, enhancedBackend, enhancedBackendSchema, httpPort, socksPort, mtu, dns
    }

    /// Supplies explicit defaults for settings absent from earlier saved profiles.
    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        allowLAN = try values.decodeIfPresent(Bool.self, forKey: .allowLAN) ?? false
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? id
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? name
        host = try values.decodeIfPresent(String.self, forKey: .host) ?? host
        port = try values.decodeIfPresent(Int.self, forKey: .port) ?? port
        serverName = try values.decodeIfPresent(String.self, forKey: .serverName) ?? serverName
        let proxyEnabled = try values.decodeIfPresent(Bool.self, forKey: .systemProxyEnabled)
        let enhancedEnabled = try values.decodeIfPresent(Bool.self, forKey: .enhancedModeEnabled)
        if let proxyEnabled, let enhancedEnabled {
            systemProxyEnabled = proxyEnabled
            enhancedModeEnabled = enhancedEnabled
        } else {
            let legacyMode = try values.decodeIfPresent(LegacyConnectionMode.self, forKey: .mode) ?? .systemProxy
            systemProxyEnabled = proxyEnabled ?? (legacyMode == .systemProxy)
            enhancedModeEnabled = enhancedEnabled ?? (legacyMode == .vpn)
        }
        enhancedBackend = try values.decodeIfPresent(EnhancedBackend.self, forKey: .enhancedBackend) ?? .localTun
        // A legacy extension selection must not opt the user into administrator TUN capture.
        #if HY2_NETWORK_EXTENSION
        let acceptedExtensionSelection = try values.decodeIfPresent(Int.self, forKey: .enhancedBackendSchema) == 1
        #else
        let acceptedExtensionSelection = false
        #endif
        if enhancedBackend == .networkExtension && !acceptedExtensionSelection {
            enhancedBackend = .localTun
            enhancedModeEnabled = false
        }
        httpPort = try values.decodeIfPresent(Int.self, forKey: .httpPort) ?? httpPort
        socksPort = try values.decodeIfPresent(Int.self, forKey: .socksPort) ?? socksPort
        mtu = try values.decodeIfPresent(Int.self, forKey: .mtu) ?? mtu
        dns = try values.decodeIfPresent([String].self, forKey: .dns) ?? dns
    }

    /// Persists independent capture choices without writing the obsolete single-mode field.
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(host, forKey: .host)
        try values.encode(port, forKey: .port)
        try values.encode(serverName, forKey: .serverName)
        try values.encode(allowLAN, forKey: .allowLAN)
        try values.encode(systemProxyEnabled, forKey: .systemProxyEnabled)
        try values.encode(enhancedModeEnabled, forKey: .enhancedModeEnabled)
        try values.encode(enhancedBackend, forKey: .enhancedBackend)
        #if HY2_NETWORK_EXTENSION
        if enhancedBackend == .networkExtension { try values.encode(1, forKey: .enhancedBackendSchema) }
        #endif
        try values.encode(httpPort, forKey: .httpPort)
        try values.encode(socksPort, forKey: .socksPort)
        try values.encode(mtu, forKey: .mtu)
        try values.encode(dns, forKey: .dns)
    }

    public var serverAddress: String { host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)" }

    public func validate(requireCapture: Bool = true) throws {
        guard !host.isEmpty, host == host.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.contains(where: { $0.isWhitespace || "/@[]?#".contains($0) }),
              !host.contains(":") || Self.isIP(host, family: AF_INET6) else {
            throw ConfigurationError.invalid("服务器请填写域名或 IP，不包含协议和端口。")
        }
        guard (1...65535).contains(port) else { throw ConfigurationError.invalid("服务器端口应在 1–65535 之间。") }
        guard !serverName.contains(where: { $0.isWhitespace || "/:@".contains($0) }) else {
            throw ConfigurationError.invalid("TLS 服务器名称格式无效。")
        }
        guard !requireCapture || systemProxyEnabled || enhancedModeEnabled else { throw ConfigurationError.invalid("请至少启用系统代理或增强模式。") }
        if systemProxyEnabled {
            guard (1024...65535).contains(httpPort), (1024...65535).contains(socksPort), httpPort != socksPort else {
                throw ConfigurationError.invalid("本地代理端口应不同，且在 1024–65535 之间。")
            }
        }
        if enhancedModeEnabled {
            guard (1280...1500).contains(mtu) else { throw ConfigurationError.invalid("MTU 应在 1280–1500 之间。") }
            guard !dns.isEmpty, dns.allSatisfy({ Self.isIP($0, family: AF_INET) || Self.isIP($0, family: AF_INET6) }) else {
                throw ConfigurationError.invalid("DNS 请填写有效的 IPv4 或 IPv6 地址。")
            }
        }
    }

    private static func isIP(_ string: String, family: Int32) -> Bool {
        var storage = in6_addr()
        return string.withCString { inet_pton(family, $0, &storage) == 1 }
    }

    /// JSON is accepted by the core's YAML parser; encoding prevents configuration injection.
    public func coreConfiguration(credentials: Credentials) throws -> Data {
        try validate()
        guard !credentials.password.isEmpty else { throw ConfigurationError.invalid("请填写认证密码。") }
        var config: [String: Any] = [
            "server": serverAddress,
            "auth": credentials.password,
            "lazy": false,
            "tls": ["sni": serverName.isEmpty ? host : serverName]
        ]
        if !credentials.obfuscationPassword.isEmpty {
            config["obfs"] = ["type": "salamander", "salamander": ["password": credentials.obfuscationPassword]]
        }
        if systemProxyEnabled {
            let listenHost = allowLAN ? "0.0.0.0" : "127.0.0.1"
            config["http"] = ["listen": "\(listenHost):\(httpPort)"]
            config["socks5"] = ["listen": "\(listenHost):\(socksPort)"]
        }
        return try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
    }
}

/// Stores authentication secrets separately from the persisted public profile settings.
public struct Credentials: Codable, Equatable, Sendable {
    public var password: String
    public var obfuscationPassword: String
    public init(password: String = "", obfuscationPassword: String = "") {
        self.password = password
        self.obfuscationPassword = obfuscationPassword
    }

    private enum CodingKeys: String, CodingKey { case password, obfuscationPassword }

    /// Supplies empty optional secrets when reading an earlier credential schema.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        password = try values.decodeIfPresent(String.self, forKey: .password) ?? ""
        obfuscationPassword = try values.decodeIfPresent(String.self, forKey: .obfuscationPassword) ?? ""
    }
}

/// Describes a configuration failure in language suitable for the application interface.
public enum ConfigurationError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case let .invalid(message) = self { message } else { nil } }
}

/// Names the transient startup fields exchanged between the app and packet-tunnel extension.
public enum TunnelWire {
    public static let configuration = "coreConfiguration"
    public static let mtu = "mtu"
    public static let dns = "dns"
}

/// Decodes the obsolete single-choice setting only when migrating an older profile.
private enum LegacyConnectionMode: String, Decodable {
    case systemProxy, vpn
}
