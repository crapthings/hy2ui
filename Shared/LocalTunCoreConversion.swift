import Foundation

/// Converts only supported core endpoint and secret fields into the helper's restricted configuration.
extension LocalTunConfiguration {
    static func fromCore(_ data: Data, profile: Profile) throws -> LocalTunConfiguration {
        guard let core = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let server = core["server"] as? String,
              let endpoint = URLComponents(string: "https://" + server),
              let rawHost = endpoint.host, let port = endpoint.port,
              let password = core["auth"] as? String else { throw LocalTunProtocolError.invalidConfiguration }
        let tls = core["tls"] as? [String: Any]
        let obfs = core["obfs"] as? [String: Any]
        let salamander = obfs?["salamander"] as? [String: Any]
        let payload = LocalTunConfiguration(host: rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), port: port,
            serverName: tls?["sni"] as? String ?? profile.serverName, password: password,
            obfuscationPassword: salamander?["password"] as? String ?? "", mtu: profile.mtu, dns: profile.dns,
            directProcesses: core["desktopDirectProcesses"] as? [String],
            bypassLocalNetworks: core["desktopBypassLocalNetworks"] as? Bool, addressRules: core["desktopAddressRules"] as? [String],
            finalDirect: try DesktopCoreConfiguration.finalDirect(in: data) ? true : nil)
        try payload.validate()
        return payload
    }
}
