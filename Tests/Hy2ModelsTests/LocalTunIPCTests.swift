import Foundation
import Darwin
import Testing
@testable import Hy2Models

/// Keeps the control socket in the root-protected installation directory within Darwin's path limit.
@Test
func localTunSocketUsesProtectedInstallationDirectory() {
    let socket = URL(fileURLWithPath: LocalTunWire.socketPath)
    #expect(socket.deletingLastPathComponent().path == LocalTunWire.installationDirectory)
    #expect(socket.lastPathComponent == "control.sock")
    let address = sockaddr_un()
    #expect(LocalTunWire.socketPath.utf8.count + 1 <= MemoryLayout.size(ofValue: address.sun_path))
}

/// Provides a valid local TUN request without starting privileged services.
private func validLocalTunConfiguration() -> LocalTunConfiguration {
    LocalTunConfiguration(host: "example.com", port: 443, serverName: "example.com", password: "test-secret")
}

/// Preserves escaped credentials across the bounded newline protocol without adding raw core fields.
@Test
func localTunRequestPreservesCredentialData() throws {
    let configuration = LocalTunConfiguration(host: "example.com", port: 443, password: "secret\nquoted\"value")
    let encoded = try LocalTunMessageCodec.encode(LocalTunRequest(command: .start, configuration: configuration))
    #expect(encoded.last == 10)
    #expect(encoded.dropLast().filter { $0 == 10 }.isEmpty)
    let decoded = try LocalTunMessageCodec.decodeRequest(Data(encoded.dropLast()))
    #expect(decoded.configuration == configuration)
}

/// Rejects caller-controlled executable paths and raw core configuration at either request level.
@Test
func localTunRequestRejectsUnknownPrivilegedFields() throws {
    let encoded = try JSONEncoder().encode(LocalTunRequest(command: .start, configuration: validLocalTunConfiguration()))
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object["executablePath"] = "/tmp/untrusted"
    #expect(throws: (any Error).self) { try LocalTunMessageCodec.decodeRequest(JSONSerialization.data(withJSONObject: object)) }
    object.removeValue(forKey: "executablePath")
    var configuration = try #require(object["configuration"] as? [String: Any])
    configuration["tls"] = ["ca": "/etc/private-file"]
    object["configuration"] = configuration
    #expect(throws: (any Error).self) { try LocalTunMessageCodec.decodeRequest(JSONSerialization.data(withJSONObject: object)) }
}

/// Rejects oversized messages and invalid network settings before privileged work can begin.
@Test
func localTunRequestRejectsInvalidBounds() throws {
    #expect(throws: (any Error).self) { try LocalTunMessageCodec.decodeRequest(Data(repeating: 32, count: LocalTunWire.maxMessageBytes + 1)) }
    for configuration in [
        LocalTunConfiguration(host: "https://example.com", port: 443, password: "secret"),
        LocalTunConfiguration(host: "example.com", port: 0, password: "secret"),
        LocalTunConfiguration(host: "example.com", port: 443, password: "secret", mtu: 9000),
        LocalTunConfiguration(host: "example.com", port: 443, password: "secret", dns: ["not-an-ip"])
    ] {
        #expect(throws: (any Error).self) { try configuration.validate() }
    }
}

/// Restricts status and stop operations to control messages without attached configuration.
@Test
func localTunControlRequestsRejectConfiguration() throws {
    let configuration = validLocalTunConfiguration()
    for command in [LocalTunCommand.status, .stop] {
        let data = try JSONEncoder().encode(LocalTunRequest(command: command, configuration: configuration))
        #expect(throws: (any Error).self) { try LocalTunMessageCodec.decodeRequest(data) }
        let control = try JSONEncoder().encode(LocalTunRequest(command: command))
        #expect(try LocalTunMessageCodec.decodeRequest(control).command == command)
    }
}
