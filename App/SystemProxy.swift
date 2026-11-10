import Foundation
import Security
import SystemConfiguration

/// Records proxy ownership before changes and restores only configuration groups still owned by this app.
@MainActor
final class SystemProxy {
    private struct Entry: Codable {
        var serviceID: String
        var original: Data
        var installed: Data
    }
    private let pacServer = PACServer()
    private var authorization: AuthorizationRef?
    private let journal: URL
    init(directory: URL) { journal = directory.appendingPathComponent("proxy-recovery.plist") }
    deinit { if let authorization { AuthorizationFree(authorization, []) } }
    var needsRecovery: Bool { FileManager.default.fileExists(atPath: journal.path) }

    func enable(httpPort: Int, socksPort: Int) throws {
        try install(SystemProxyConfiguration.manual(httpPort: httpPort, socksPort: socksPort))
    }

    func enablePAC(configuration: RoutingConfiguration, httpPort: Int) async throws {
        guard !needsRecovery else { throw ConfigurationError.invalid("请先恢复上次连接的系统代理。") }
        try configuration.validate()
        do {
            let url: String
            if configuration.mode == .generatedPAC {
                url = try await pacServer.start(script: PACScript.generate(configuration: configuration, httpPort: httpPort)).absoluteString
            } else { url = configuration.pacURL }
            try Task.checkCancellation()
            var settings = SystemProxyConfiguration.pac(url: url)
            settings["ProxyAutoConfigJavaScript"] = ""
            try install(settings)
        } catch {
            if !needsRecovery { pacServer.stop() }
            throw error
        }
    }

    private func install(_ requested: [String: Any]) throws {
        guard !needsRecovery else { throw ConfigurationError.invalid("请先恢复上次连接的系统代理。") }
        try transaction { preferences in
            guard let set = SCNetworkSetCopyCurrent(preferences),
                  let services = SCNetworkSetCopyServices(set) as? [SCNetworkService] else { throw self.failure() }
            var entries: [Entry] = []
            var changes: [(SCNetworkProtocol, [String: Any])] = []
            for service in services where SCNetworkServiceGetEnabled(service) {
                guard let serviceID = SCNetworkServiceGetServiceID(service),
                      let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) else { continue }
                let original = SCNetworkProtocolGetConfiguration(proto) as? [String: Any] ?? [:]
                var installed = requested
                let fallback: [String: Any] = ["HTTPProxy": "", "HTTPPort": 0, "HTTPSProxy": "", "HTTPSPort": 0,
                    "SOCKSProxy": "", "SOCKSPort": 0, "ProxyAutoConfigURLString": "", "ProxyAutoConfigJavaScript": ""]
                for (key, value) in fallback where installed[key] == nil { installed[key] = original[key] ?? value }
                var updated = original
                updated.merge(installed) { _, new in new }
                entries.append(Entry(serviceID: serviceID as String,
                    original: try Self.encode(original), installed: try Self.encode(installed)))
                changes.append((proto, updated))
            }
            guard !entries.isEmpty else { throw ConfigurationError.invalid("没有可设置代理的网络服务。") }
            // A durable recovery record must exist before changing preferences.
            try PropertyListEncoder().encode(entries).write(to: journal, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path)
            for (proto, config) in changes {
                guard SCNetworkProtocolSetConfiguration(proto, config as CFDictionary) else { throw self.failure() }
            }
        }
    }

    func restore() throws {
        guard needsRecovery else { pacServer.stop(); return }
        let entries = try PropertyListDecoder().decode([Entry].self, from: Data(contentsOf: journal))
        try transaction { preferences in
            for entry in entries {
                guard let service = SCNetworkServiceCopy(preferences, entry.serviceID as CFString),
                      let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) else { continue }
                var current = SCNetworkProtocolGetConfiguration(proto) as? [String: Any] ?? [:]
                let original = try Self.decode(entry.original)
                let installed = try Self.decode(entry.installed)
                current = ProxyOwnership.restore(current: current, original: original, installed: installed)
                guard SCNetworkProtocolSetConfiguration(proto, current as CFDictionary) else { throw self.failure() }
            }
        }
        try FileManager.default.removeItem(at: journal)
        pacServer.stop()
    }

    private func transaction(_ body: (SCPreferences) throws -> Void) throws {
        if authorization == nil {
            guard AuthorizationCreate(nil, nil, [], &authorization) == errAuthorizationSuccess else {
                throw ConfigurationError.invalid("无法创建网络设置授权。")
            }
        }
        guard let authorization else { throw ConfigurationError.invalid("无法创建网络设置授权。") }
        guard let preferences = SCPreferencesCreateWithAuthorization(nil, "Hy2UI" as CFString, nil, authorization) else { throw failure() }
        guard SCPreferencesLock(preferences, true) else { throw failure() }
        defer { SCPreferencesUnlock(preferences) }
        try body(preferences)
        guard SCPreferencesCommitChanges(preferences), SCPreferencesApplyChanges(preferences) else { throw failure() }
    }
    private func failure() -> ConfigurationError {
        .invalid("系统代理设置失败：\(String(cString: SCErrorString(SCError())))")
    }
    private static func encode(_ dictionary: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
    }
    private static func decode(_ data: Data) throws -> [String: Any] {
        guard let settings = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw ConfigurationError.invalid("系统代理恢复记录格式无效，已保留记录供恢复。")
        }
        return settings
    }
}
