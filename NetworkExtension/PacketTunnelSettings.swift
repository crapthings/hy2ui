import Foundation
import Darwin
import NetworkExtension

/// Builds value-only NE settings; this function never applies system network changes.
enum PacketTunnelSettings {
    static func make(_ configuration: PacketTunnelConfiguration) throws -> NEPacketTunnelNetworkSettings {
        try configuration.validate()
        let endpoint = try configuration.endpoint
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: endpoint.address)
        settings.mtu = NSNumber(value: configuration.input.mtu)
        let ipv4 = NEIPv4Settings(addresses: ["100.100.100.101"], subnetMasks: ["255.255.255.252"])
        ipv4.includedRoutes = [.default()]
        var excluded4 = try LocalNetworkPolicy.ipv4.map { try ipv4Route($0) }
        if endpoint.family == Int32(AF_INET) {
            excluded4.append(NEIPv4Route(destinationAddress: endpoint.address, subnetMask: "255.255.255.255"))
        }
        ipv4.excludedRoutes = excluded4
        settings.ipv4Settings = ipv4
        let ipv6 = NEIPv6Settings(addresses: ["fd72:6832::1"], networkPrefixLengths: [126])
        ipv6.includedRoutes = [.default()]
        var excluded6 = try LocalNetworkPolicy.ipv6.map { value -> NEIPv6Route in
            let network = try IPNetwork(value)
            return NEIPv6Route(destinationAddress: network.address, networkPrefixLength: NSNumber(value: network.prefix))
        }
        if endpoint.family == Int32(AF_INET6) {
            excluded6.append(NEIPv6Route(destinationAddress: endpoint.address, networkPrefixLength: 128))
        }
        ipv6.excludedRoutes = excluded6
        settings.ipv6Settings = ipv6
        let dns = NEDNSSettings(servers: configuration.input.dns)
        dns.matchDomains = [""]
        dns.matchDomainsNoSearch = true
        settings.dnsSettings = dns
        return settings
    }

    private static func ipv4Route(_ value: String) throws -> NEIPv4Route {
        let network = try IPNetwork(value)
        guard !network.isIPv6, (1...32).contains(network.prefix) else { throw LocalTunProtocolError.invalidConfiguration }
        let bits = UInt32.max << (32 - network.prefix)
        let mask = [24, 16, 8, 0].map { String((bits >> $0) & 255) }.joined(separator: ".")
        return NEIPv4Route(destinationAddress: network.address, subnetMask: mask)
    }
}
