import Testing
@testable import Hy2Models

/// Validates numeric settings before changing a profile even when the associated capture mode is disabled.
@Test func settingsNumbersValidateBeforeMutation() throws {
    let profile = Profile()
    #expect(try SettingsInput.applying(" 1450 ", field: .mtu, to: profile).mtu == 1450)
    #expect(try SettingsInput.applying("19080", field: .httpPort, to: profile).httpPort == 19080)
    for value in ["", "abc", "1400x", "1279", "1501", "999999999999999999999999"] {
        #expect(throws: (any Error).self) { try SettingsInput.applying(value, field: .mtu, to: profile) }
    }
    #expect(profile.mtu == 1400)
    #expect(throws: (any Error).self) { try SettingsInput.applying("11080", field: .httpPort, to: profile) }
    #expect(throws: (any Error).self) { try SettingsInput.applying("18080", field: .socksPort, to: profile) }
    #expect(throws: (any Error).self) { try SettingsInput.applying("80", field: .httpPort, to: profile) }
}

/// Accepts complete mixed-family DNS lists while rejecting partial input and helper-incompatible list lengths.
@Test func settingsDNSCommitsOnlyCompleteAddresses() throws {
    let profile = Profile()
    let updated = try SettingsInput.applying(" 8.8.8.8 , 2606:4700:4700::1111 ", field: .dns, to: profile)
    #expect(updated.dns == ["8.8.8.8", "2606:4700:4700::1111"])
    #expect(updated.id == profile.id && updated.httpPort == profile.httpPort)
    for value in ["", "1.1.", "1.1.1.1,", "dns.example.com", "[::1]", Array(repeating: "1.1.1.1", count: 9).joined(separator: ",")] {
        #expect(throws: (any Error).self) { try SettingsInput.applying(value, field: .dns, to: profile) }
    }
    #expect(profile.dns == Profile().dns)
}
