import Foundation
import Darwin

/// Parses and canonicalizes IPv4 or IPv6 prefixes without DNS lookups.
public struct IPNetwork: Equatable, Sendable {
    public let bytes: [UInt8]
    public let prefix: Int
    public var isIPv6: Bool { bytes.count == 16 }
    public var address: String {
        var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        bytes.withUnsafeBytes { _ = inet_ntop(isIPv6 ? AF_INET6 : AF_INET, $0.baseAddress, &output, socklen_t(output.count)) }
        return String(cString: output)
    }
    public var cidr: String { "\(address)/\(prefix)" }
    public var mask: String { (0..<4).map { String(UInt8(truncatingIfNeeded: 0xff << max(0, min(8, 8 - (prefix - $0 * 8))))) }.joined(separator: ".") }

    public init(_ input: String) throws {
        let parts = input.split(separator: "/", omittingEmptySubsequences: false)
        guard !input.contains("%"), parts.count <= 2, let literal = parts.first, !literal.isEmpty else { throw IPNetworkError.invalid }
        let family = literal.contains(":") ? AF_INET6 : AF_INET
        let size = family == AF_INET6 ? 16 : 4
        var data = [UInt8](repeating: 0, count: size)
        guard String(literal).withCString({ inet_pton(family, $0, &data) }) == 1 else { throw IPNetworkError.invalid }
        let bits: Int
        if parts.count == 2 {
            guard !parts[1].isEmpty, parts[1].utf8.allSatisfy({ (48...57).contains($0) }), let value = Int(parts[1]), (0...size * 8).contains(value) else { throw IPNetworkError.invalid }
            bits = value
        } else { bits = size * 8 }
        for i in data.indices { data[i] &= UInt8(truncatingIfNeeded: 0xff << max(0, min(8, 8 - (bits - i * 8)))) }
        bytes = data; prefix = bits
    }
    public func contains(_ other: IPNetwork) -> Bool {
        guard bytes.count == other.bytes.count, prefix <= other.prefix else { return false }
        return bytes.indices.allSatisfy { i in
            let mask = UInt8(truncatingIfNeeded: 0xff << max(0, min(8, 8 - (prefix - i * 8))))
            return bytes[i] == other.bytes[i] & mask
        }
    }
}

/// Reports an invalid literal address or prefix without echoing user input.
public enum IPNetworkError: LocalizedError {
    case invalid
    public var errorDescription: String? { "请输入有效的 IPv4、IPv6 或 CIDR 网段。" }
}

/// Defines shared local-network bypass defaults while leaving synthetic DNS and CGNAT ranges untouched.
public enum LocalNetworkPolicy {
    public static let ipv4 = ["127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "224.0.0.0/4", "255.255.255.255/32"]
    public static let ipv6 = ["::1/128", "fc00::/7", "fe80::/10", "ff00::/8"]
    public static let domains = ["localhost", "*.localhost", "local", "*.local", "home.arpa", "*.home.arpa"]
    public static let proxyExceptions = domains + ipv4 + ipv6
}
