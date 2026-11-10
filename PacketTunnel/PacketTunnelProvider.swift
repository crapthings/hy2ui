import Foundation
import NetworkExtension
import OSLog

/// Installs system tunnel settings and serializes packet-engine lifecycle transitions.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let lifecycleQueue = DispatchQueue(label: "dev.hy2ui.tunnel-lifecycle")
    private lazy var engine = PacketEngine(queue: lifecycleQueue)
    private var sessions = SessionGeneration<Void>()
    private let logger = Logger(subsystem: "dev.hy2ui.app.tunnel", category: "lifecycle")

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        guard let config = options?[TunnelWire.configuration] as? Data,
              let mtu = options?[TunnelWire.mtu] as? NSNumber,
              let dns = options?[TunnelWire.dns] as? [String] else {
            completionHandler(ConfigurationError.invalid("请从 Hy2UI 发起连接；此版本不支持系统自动启动。"))
            return
        }
        guard let core = try? DesktopCoreConfiguration.coreOnly(config), (1280...1500).contains(mtu.intValue), !dns.isEmpty else {
            completionHandler(ConfigurationError.invalid("隧道网络配置无效。"))
            return
        }
        lifecycleQueue.async {
            let token = self.sessions.begin { result in
                switch result {
                case .success: completionHandler(nil)
                case let .failure(error): completionHandler(error)
                }
            }
            self.engine.stop()
            self.engine.start(session: token, configuration: core, mtu: mtu.intValue, completion: { result in
                guard self.sessions.contains(token) else { return }
                switch result {
                case let .failure(error): self.sessions.finish(token, result: .failure(error))
                case let .success(remoteAddress):
                    self.installSettings(remoteAddress: remoteAddress, mtu: mtu, dns: dns, bypass: (options?["bypassLocalNetworks"] as? NSNumber)?.boolValue ?? true, session: token)
                }
            }, failure: { error in
                guard self.sessions.contains(token) else { return }
                self.sessions.finish(token, result: .failure(error))
                self.sessions.invalidate()
                self.logger.error("Packet engine stopped")
                self.cancelTunnelWithError(error)
            })
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        lifecycleQueue.async {
            self.sessions.invalidate()
            self.engine.stop()
            completionHandler()
        }
    }

    private func installSettings(remoteAddress: String, mtu: NSNumber, dns: [String], bypass: Bool, session: UUID) {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: remoteAddress)
        let ipv4 = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [.default()]
        if bypass { ipv4.excludedRoutes = LocalNetworkPolicy.ipv4.compactMap { try? IPNetwork($0) }.map { NEIPv4Route(destinationAddress: $0.address, subnetMask: $0.mask) } }
        let ipv6 = NEIPv6Settings(addresses: ["fd72:6832::1"], networkPrefixLengths: [64])
        ipv6.includedRoutes = [.default()]
        if bypass { ipv6.excludedRoutes = LocalNetworkPolicy.ipv6.compactMap { try? IPNetwork($0) }.map { NEIPv6Route(destinationAddress: $0.address, networkPrefixLength: NSNumber(value: $0.prefix)) } }
        settings.ipv4Settings = ipv4
        settings.ipv6Settings = ipv6
        settings.mtu = mtu
        let dnsSettings = NEDNSSettings(servers: dns)
        dnsSettings.matchDomains = [""]
        settings.dnsSettings = dnsSettings
        setTunnelNetworkSettings(settings) { error in
            self.lifecycleQueue.async {
                guard self.sessions.contains(session) else { return }
                if let error {
                    self.engine.stop(session: session)
                    self.sessions.finish(session, result: .failure(error))
                } else if self.engine.attach(flow: self.packetFlow, session: session) {
                    self.logger.info("Packet tunnel connected")
                    self.sessions.finish(session, result: .success(()))
                } else {
                    self.sessions.finish(session, result: .failure(ConfigurationError.invalid("隧道启动已取消。")))
                }
            }
        }
    }
}
