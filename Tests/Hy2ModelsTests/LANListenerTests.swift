import Foundation
import Testing
@testable import Hy2Models

/// Requires explicit LAN opt-in and preserves it independently of the selected server.
@Test func lanListenersRequireOptIn() throws {
    var profile = Profile()
    profile.host = "example.com"
    let credentials = Credentials(password: "fixture", obfuscationPassword: "")
    func listeners(_ profile: Profile) throws -> [String] {
        let value = try JSONSerialization.jsonObject(with: profile.coreConfiguration(credentials: credentials)) as! [String: Any]
        return ["http", "socks5"].compactMap { (value[$0] as? [String: String])?["listen"] }
    }
    #expect(try listeners(profile) == ["127.0.0.1:18080", "127.0.0.1:11080"])
    profile.allowLAN = true
    #expect(try listeners(profile) == ["0.0.0.0:18080", "0.0.0.0:11080"])
    #expect(ServiceConfiguration(profile: profile).applying(to: Profile()).allowLAN)
    var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as! [String: Any]
    legacy.removeValue(forKey: "allowLAN")
    let migrated = try JSONDecoder().decode(Profile.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(!migrated.allowLAN)
    profile.systemProxyEnabled = false
    profile.enhancedModeEnabled = true
    #expect(try listeners(profile).isEmpty)
}
