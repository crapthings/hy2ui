import Foundation

/// Exercises PAC loopback serving and preference drafts without changing system networking.
@main struct RoutingSmoke {
    @MainActor static func main() async throws {
        let suite = "Hy2UI.RoutingSmoke.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = RoutingPreferences(defaults: defaults)
        try preferences.update { $0.mode = .externalPAC }
        precondition(preferences.configuration.mode == .externalPAC)
        let restored = RoutingPreferences(defaults: defaults)
        precondition(restored.error == nil && restored.configuration.mode == .manual)
        try preferences.update { $0.pacURL = "https://example.com/proxy.pac" }
        precondition(RoutingPreferences(defaults: defaults).configuration.mode == .externalPAC)
        let own = ProcessIdentity.read(pid: UInt32(ProcessInfo.processInfo.processIdentifier))!
        precondition(own.isCurrent)
        let stale = ProcessIdentity(pid: own.pid, startSeconds: own.startSeconds + 1,
                                    startMicroseconds: own.startMicroseconds, target: own.target)
        precondition(!stale.isCurrent)
        precondition(ProcessIdentity.read(pid: 0) == nil && ProcessIdentity.read(pid: UInt32.max) == nil)
        try preferences.update { try ProcessRoutingPolicy.set(.direct, for: own.target, in: &$0) }
        precondition(RoutingPreferences(defaults: defaults).configuration.directProcesses == [own.target.path])
        try preferences.update { try ProcessRoutingPolicy.set(.defaultRules, for: own.target, in: &$0) }
        precondition(RoutingPreferences(defaults: defaults).configuration.directProcesses.isEmpty)
        let saved = preferences.configuration
        do {
            try preferences.update { configuration in
                configuration.directProcesses = (0..<63).map { "test\($0)" }
                for path in ["/test/one", "/test/two"] {
                    try ProcessRoutingPolicy.set(.direct, for: ProcessRoutingTarget(path: path), in: &configuration)
                }
            }
            preconditionFailure("oversized batch should fail")
        } catch {}
        precondition(preferences.configuration == saved)
        precondition(RoutingPreferences(defaults: defaults).configuration == saved)
        let server = PACServer()
        let url = try await server.start(script: "function FindProxyForURL(){ return 'DIRECT'; }")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: url)
        precondition((response as? HTTPURLResponse)?.statusCode == 200)
        precondition(String(decoding: data, as: UTF8.self).contains("FindProxyForURL"))
        precondition(response.mimeType == "application/x-ns-proxy-autoconfig")
        var request = URLRequest(url: url); request.httpMethod = "HEAD"
        let (head, header) = try await session.data(for: request)
        precondition(head.isEmpty && (header as? HTTPURLResponse)?.statusCode == 200)
        let (_, missing) = try await session.data(from: url.deletingLastPathComponent().appendingPathComponent("wrong"))
        precondition((missing as? HTTPURLResponse)?.statusCode == 404)
        let pending = Task { try await server.start(script: "cancelled") }
        pending.cancel()
        do { _ = try await pending.value; preconditionFailure("cancelled startup succeeded") } catch {}
        let restart = try await server.start(script: "restart")
        let (newData, _) = try await session.data(from: restart)
        precondition(newData == Data("restart".utf8) && restart != url)
        server.stop()
        print("PAC loopback GET/HEAD, wrong path, cancellation, restart preference draft, persistent process actions and stale PID checks passed")
    }
}
