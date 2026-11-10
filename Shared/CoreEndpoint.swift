import Foundation
import Darwin

/// Resolves a server before tunnel setup while preserving its TLS identity.
public enum CoreEndpoint {
    /// Resolve before installing tunnel DNS. Reconnects reuse the address and retain TLS SNI.
    /// Call on a worker queue: getaddrinfo is a blocking system resolver.
    public static func resolve(configuration: Data) throws -> (configuration: Data, address: String) {
        guard var object = try JSONSerialization.jsonObject(with: configuration) as? [String: Any],
              let authority = object["server"] as? String,
              let url = URLComponents(string: "https://" + authority),
              let rawHost = url.host, let port = url.port else {
            throw ConfigurationError.invalid("服务器地址无效。")
        }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_protocol = IPPROTO_UDP
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &result)
        guard status == 0, let result else {
            throw ConfigurationError.invalid("服务器 DNS 解析失败：\(String(cString: gai_strerror(status)))")
        }
        defer { freeaddrinfo(result) }
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(result.pointee.ai_addr, result.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else {
            throw ConfigurationError.invalid("无法读取服务器 IP。")
        }
        let address = String(cString: buffer)
        object["server"] = address.contains(":") ? "[\(address)]:\(port)" : "\(address):\(port)"
        var tls = object["tls"] as? [String: Any] ?? [:]
        if (tls["sni"] as? String ?? "").isEmpty { tls["sni"] = host }
        object["tls"] = tls
        return (try JSONSerialization.data(withJSONObject: object, options: .sortedKeys), address)
    }
}
