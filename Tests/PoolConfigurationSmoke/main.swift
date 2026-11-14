import Foundation

/// Emits only fixture configurations for cross-language offline checks with the selected core.
@main struct PoolConfigurationSmoke {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let report = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        let capabilities = try CorePoolCapabilities.parse(report)
        var a = Profile(); a.host = "line-a.invalid"; a.name = "a"
        var b = Profile(); b.host = "line-b.invalid"; b.name = "b"
        let secrets = [a.id: Credentials(password: "fixture-a", obfuscationPassword: ""), b.id: Credentials(password: "fixture-b", obfuscationPassword: "")]
        for kind in [ServerGroupKind.urlTest, .fallback, .loadBalance] {
            var group = ServerGroup(); group.kind = kind; group.members = [a.id,b.id]; group.selectedID = a.id
            let base = try a.coreConfiguration(credentials: secrets[a.id]!)
            let pool = try ClientPoolConfiguration.applying(to: base, group: group, servers: [a,b], credentials: secrets, capabilities: capabilities)
            let data = try NativeClientRouting.applying(to: pool, routing: RoutingConfiguration())
            try data.write(to: root.appendingPathComponent(kind.rawValue + ".json"))
        }
    }
}
