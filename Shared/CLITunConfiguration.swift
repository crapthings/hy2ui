import Foundation
import Darwin

/// Builds only upstream-supported TUN settings from the helper's bounded, validated request.
public enum CLITunConfiguration {
    public static func make(_ input: LocalTunConfiguration) throws -> Data {
        try input.validate()
        // Custom worker fields must never be silently ignored at the privileged boundary.
        guard input.directProcesses?.isEmpty != false, input.addressRules?.isEmpty != false,
              input.finalDirect != true else { throw LocalTunProtocolError.invalidConfiguration }
        let endpoint = try resolve(host: input.host)
        let ipv6 = endpoint.contains(":")
        let name = try interfaceName()
        let bypass = input.bypassLocalNetworks ?? true
        let routes4 = try captureRoutes(ipv6: false, bypass: bypass)
        let routes6 = try captureRoutes(ipv6: true, bypass: bypass)
        var object: [String: Any] = [
            "server": ipv6 ? "[\(endpoint)]:\(input.port)" : "\(endpoint):\(input.port)",
            "auth": input.password,
            "tls": ["sni": input.serverName.isEmpty ? input.host : input.serverName],
            "tun": [
                "name": name, "mtu": input.mtu, "timeout": "60s",
                "address": ["ipv4": "198.18.0.1/30", "ipv6": "fd72:6832::1/126"],
                "route": ["strict": false, "ipv4": routes4, "ipv6": routes6,
                          "ipv4Exclude": ipv6 ? [] : ["\(endpoint)/32"],
                          "ipv6Exclude": ipv6 ? ["\(endpoint)/128"] : []]
            ]
        ]
        if !input.obfuscationPassword.isEmpty {
            object["obfs"] = ["type": "salamander", "salamander": ["password": input.obfuscationPassword]]
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// Subtracts local prefixes instead of creating potentially conflicting physical exclusion routes.
    public static func captureRoutes(ipv6: Bool, bypass: Bool) throws -> [String] {
        var routes = try (ipv6 ? ["::/1", "8000::/1"] : ["0.0.0.0/1", "128.0.0.0/1"]).map(IPNetwork.init)
        if bypass {
            for value in ipv6 ? LocalNetworkPolicy.ipv6 : LocalNetworkPolicy.ipv4 {
                let excluded = try IPNetwork(value)
                routes = try routes.flatMap { try subtract(excluded, from: $0) }
            }
        }
        return routes.map(\.cidr)
    }

    private static func subtract(_ excluded: IPNetwork, from network: IPNetwork) throws -> [IPNetwork] {
        if excluded.contains(network) { return [] }
        if !network.contains(excluded) { return [network] }
        let prefix = network.prefix + 1
        var upper = network.bytes
        upper[network.prefix / 8] |= UInt8(1 << (7 - network.prefix % 8))
        var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        upper.withUnsafeBytes { _ = inet_ntop(network.isIPv6 ? AF_INET6 : AF_INET, $0.baseAddress, &text, socklen_t(text.count)) }
        let lower = try IPNetwork("\(network.address)/\(prefix)")
        let higher = try IPNetwork("\(String(cString: text))/\(prefix)")
        return try subtract(excluded, from: lower) + subtract(excluded, from: higher)
    }

    private static func resolve(host: String) throws -> String {
        // The UI resolves before capture; the privileged helper accepts only a frozen numeric address.
        guard !host.contains("/"), let address = try? IPNetwork(host) else {
            throw LocalTunProtocolError.invalidConfiguration
        }
        return address.address
    }

    private static func interfaceName() throws -> String {
        let start = 100 + Int(getpid()) % 10_000
        for index in start..<(start + 64) {
            let name = "utun\(index)"
            if name.withCString({ if_nametoindex($0) }) == 0 { return name }
        }
        throw LocalTunProtocolError.invalidConfiguration
    }
}
