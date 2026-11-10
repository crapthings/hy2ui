import Foundation
import SystemConfiguration

/// Publishes session-owned supplemental resolvers so existing home and search domains retain physical DNS.
final class LocalDNSResolvers {
    private var store: SCDynamicStore?
    private var keys: [String] = []

    func prepare(services: [SCNetworkService], enabled: Bool) throws {
        clear()
        guard enabled else { return }
        let options = [kSCDynamicStoreUseSessionKeys as String: true] as CFDictionary
        guard let store = SCDynamicStoreCreateWithOptions(nil, "Hy2UI local DNS" as CFString, options, nil, nil) else { throw HelperFailure("无法保留本地域名解析。") }
        self.store = store
        let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
            ?? SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv6" as CFString) as? [String: Any]
        let primary = global?["PrimaryService"] as? String
        do {
            for service in services where SCNetworkServiceGetEnabled(service) {
                guard let identifier = SCNetworkServiceGetServiceID(service) as String?,
                      let interface = SCNetworkServiceGetInterface(service),
                      let name = SCNetworkInterfaceGetBSDName(interface) as String?, name.hasPrefix("en"),
                      let dns = SCDynamicStoreCopyValue(store, "State:/Network/Service/\(identifier)/DNS" as CFString) as? [String: Any] else { continue }
                let servers = LocalDNSPolicy.servers(dns[kSCPropNetDNSServerAddresses as String] as? [String] ?? [])
                guard !servers.isEmpty else { continue }
                var search = dns[kSCPropNetDNSSearchDomains as String] as? [String] ?? []
                if let domain = dns[kSCPropNetDNSDomainName as String] as? String { search.append(domain) }
                let domains = LocalDNSPolicy.domains(search: search, includeHome: identifier == primary)
                guard !domains.isEmpty else { continue }
                let key = "State:/Network/Service/dev.hy2ui.local-dns.\(keys.count)/DNS"
                let resolver: [String: Any] = [kSCPropNetDNSServerAddresses as String: servers,
                    kSCPropNetDNSSupplementalMatchDomains as String: domains,
                    kSCPropNetDNSSupplementalMatchOrders as String: domains.map { _ in 1000 }]
                guard SCDynamicStoreSetValue(store, key as CFString, resolver as CFDictionary) else { throw HelperFailure("无法保留本地域名解析。") }
                keys.append(key)
            }
        } catch { clear(); throw error }
    }
    func clear() {
        if let store { for key in keys { SCDynamicStoreRemoveValue(store, key as CFString) } }
        keys.removeAll(); store = nil
    }
}
