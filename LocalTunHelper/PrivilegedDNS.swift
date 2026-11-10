import Foundation
import SystemConfiguration
import Darwin

/// Restores only the DNS server-address list still owned by the local TUN session.
final class PrivilegedDNS {
    private struct Entry: Codable {
        let serviceID: String
        let original: [String]?
        let installed: [String]
    }
    private let journal = URL(fileURLWithPath: LocalTunWire.journalPath)
    var needsRecovery: Bool { var metadata = stat(); return lstat(journal.path, &metadata) == 0 }

    func enable(servers: [String]) throws {
        guard !needsRecovery else { throw HelperFailure("存在待恢复的 DNS 设置，请先恢复。") }
        try transaction { preferences in
            guard let set = SCNetworkSetCopyCurrent(preferences),
                  let services = SCNetworkSetCopyServices(set) as? [SCNetworkService] else { throw failure() }
            var entries: [Entry] = []
            var changes: [(SCNetworkProtocol, [String: Any])] = []
            for service in services where SCNetworkServiceGetEnabled(service) {
                guard let serviceID = SCNetworkServiceGetServiceID(service),
                      let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeDNS) else { continue }
                var original = SCNetworkProtocolGetConfiguration(proto) as? [String: Any] ?? [:]
                let key = kSCPropNetDNSServerAddresses as String
                guard original[key] == nil || original[key] is [String] else { throw failure() }
                entries.append(Entry(serviceID: serviceID as String, original: original[key] as? [String], installed: servers))
                original[key] = servers
                changes.append((proto, original))
            }
            guard !entries.isEmpty else { throw HelperFailure("没有可设置 DNS 的网络服务。") }
            try writeJournal(entries)
            for (proto, settings) in changes {
                guard SCNetworkProtocolSetConfiguration(proto, settings as CFDictionary) else { throw failure() }
            }
        }
    }

    func restore() throws {
        guard needsRecovery else { return }
        try TrustedInstallation.requireRootFile(journal.path)
        let data = try Data(contentsOf: journal)
        guard data.count <= 1_048_576 else { throw HelperFailure("DNS 恢复记录大小无效。") }
        let entries = try PropertyListDecoder().decode([Entry].self, from: data)
        try transaction { preferences in
            for entry in entries {
                guard let service = SCNetworkServiceCopy(preferences, entry.serviceID as CFString),
                      let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeDNS) else { continue }
                var current = SCNetworkProtocolGetConfiguration(proto) as? [String: Any] ?? [:]
                let key = kSCPropNetDNSServerAddresses as String
                guard current[key] as? [String] == entry.installed else { continue }
                current[key] = entry.original
                guard SCNetworkProtocolSetConfiguration(proto, current as CFDictionary) else { throw failure() }
            }
        }
        try FileManager.default.removeItem(at: journal)
    }

    private func writeJournal(_ entries: [Entry]) throws {
        let data = try PropertyListEncoder().encode(entries)
        try data.write(to: journal, options: .atomic)
        guard chmod(journal.path, 0o600) == 0 else { throw failure() }
        try TrustedInstallation.requireRootFile(journal.path)
    }

    private func transaction(_ operation: (SCPreferences) throws -> Void) throws {
        guard let preferences = SCPreferencesCreate(nil, "Hy2UI local TUN" as CFString, nil) else { throw failure() }
        let deadline = ContinuousClock.now + .seconds(5)
        while !SCPreferencesLock(preferences, false) {
            guard SCError() == kSCStatusPrefsBusy, ContinuousClock.now < deadline else { throw failure() }
            Thread.sleep(forTimeInterval: 0.02)
        }
        defer { SCPreferencesUnlock(preferences) }
        try operation(preferences)
        guard SCPreferencesCommitChanges(preferences), SCPreferencesApplyChanges(preferences) else { throw failure() }
    }

    private func failure() -> HelperFailure { HelperFailure("无法更新或恢复系统 DNS 设置。") }
}
