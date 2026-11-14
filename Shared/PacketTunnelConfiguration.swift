import Foundation
import Darwin

/// Carries bounded in-memory provider input; it is never stored in VPN preferences.
public struct PacketTunnelConfiguration: Codable, Sendable {
    public let schemaVersion: Int
    public let input: LocalTunConfiguration
    public let physicalInterface: String
    public static let optionsKey = "hy2ui.packet-configuration.v1"
    public static let maximumBytes = 65_536

    public init(input: LocalTunConfiguration, physicalInterface: String) throws {
        self.schemaVersion = 1
        self.input = input
        self.physicalInterface = physicalInterface
        try validate()
    }

    public var endpoint: PacketTunnelEndpoint {
        get throws {
            let authority = input.host.contains(":") ? "[\(input.host)]:\(input.port)" : "\(input.host):\(input.port)"
            return try PacketTunnelEndpoint(server: authority, tlsServerName: input.serverName)
        }
    }

    public func validate() throws {
        try input.validate()
        guard schemaVersion == 1, input.directProcesses?.isEmpty != false,
              input.addressRules?.isEmpty != false, input.finalDirect != true,
              (input.bypassLocalNetworks ?? true),
              !physicalInterface.isEmpty, physicalInterface.utf8.count <= 15,
              physicalInterface.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0) }),
              !["lo", "utun", "tun", "tap", "ppp", "ipsec", "gif", "stf", "awdl", "llw"].contains(where: { physicalInterface.hasPrefix($0) }) else {
            throw LocalTunProtocolError.invalidConfiguration
        }
        _ = try endpoint
        for address in input.dns {
            let authority = address.contains(":") ? "[\(address)]:53" : "\(address):53"
            _ = try PacketTunnelEndpoint(server: authority, tlsServerName: "resolver")
        }
    }

    public func encoded() throws -> Data {
        try validate()
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumBytes else { throw LocalTunProtocolError.messageTooLarge }
        return data
    }

    public static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumBytes else { throw LocalTunProtocolError.messageTooLarge }
        let result = try JSONDecoder().decode(Self.self, from: data)
        try result.validate()
        return result
    }

    public func coreConfiguration() throws -> Data {
        try validate()
        let endpoint = try self.endpoint
        var object: [String: Any] = [
            "server": endpoint.family == Int32(AF_INET6) ? "[\(endpoint.address)]:\(endpoint.port)" : "\(endpoint.address):\(endpoint.port)",
            "auth": input.password, "tls": ["sni": endpoint.tlsServerName], "lazy": false,
            "quic": ["sockopts": ["bindInterface": physicalInterface]],
            "tun": ["name": "host-owned-packet-flow", "mtu": input.mtu, "timeout": "60s"]
        ]
        if !input.obfuscationPassword.isEmpty {
            object["obfs"] = ["type": "salamander", "salamander": ["password": input.obfuscationPassword]]
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
