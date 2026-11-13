import Foundation
import Darwin
import Testing
@testable import Hy2Models

/// Verifies session identity bounds and compatibility without creating or deleting any interface.
struct LocalTunSessionTests {
    private func fixture(name: String = "utun321", owner: String = "dev.hy2ui") -> LocalTunInterfaceSession {
        LocalTunInterfaceSession(id: UUID().uuidString, owner: owner,
            process: LocalTunProcessIdentity(pid: 1234, startSeconds: 100, startMicroseconds: 7),
            interface: LocalTunInterfaceIdentity(name: name, index: 42))
    }
    @Test func identityRoundTripsWithoutCredentialsAndOldEventsStillDecode() throws {
        let session = fixture(); try session.validate()
        let bytes = try LocalTunMessageCodec.encode(LocalTunEvent(kind: .ready, interfaceSession: session))
        let decoded = try JSONDecoder().decode(LocalTunEvent.self, from: bytes)
        #expect(decoded.interfaceSession == session)
        #expect(!String(decoding: bytes, as: UTF8.self).contains("password"))
        let old = try JSONDecoder().decode(LocalTunEvent.self, from: Data(#"{"kind":"ready"}"#.utf8))
        #expect(old.interfaceSession == nil)
    }
    @Test func invalidOwnersAndInterfaceNamesAreRejected() {
        for session in [fixture(name: "en1"), fixture(name: "utun"), fixture(name: "utun1;cmd"), fixture(owner: "another.app")] {
            #expect(throws: (any Error).self) { try session.validate() }
        }
        #expect(!LocalTunProcessIdentity(pid: 1, startSeconds: 100, startMicroseconds: 0).isValid)
        #expect(!LocalTunProcessIdentity(pid: UInt32(getpid()), startSeconds: 1, startMicroseconds: 0).isCurrent)
    }
    @Test func managedConfigRequiresJournalAndParentAndKeepsIDsOffTheRequestWire() throws {
        let input = LocalTunConfiguration(host: "192.0.2.1", port: 443, password: "fixture")
        let id = UUID()
        #expect(throws: (any Error).self) { try CLITunConfiguration.make(input, sessionID: id, parentPID: 42) }
        #expect(throws: (any Error).self) { try CLITunConfiguration.make(input, routeJournalPath: LocalTunWire.routeJournalPath, sessionID: id) }
        let data = try CLITunConfiguration.make(input, routeJournalPath: LocalTunWire.routeJournalPath, sessionID: id, parentPID: 42)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let session = try #require((object["tun"] as? [String: Any])?["session"] as? [String: Any])
        #expect(session["id"] as? String == id.uuidString)
        #expect(session["owner"] as? String == "dev.hy2ui")
        #expect(session["parentPid"] as? Int == 42)
        #expect(!String(decoding: try JSONEncoder().encode(input), as: UTF8.self).contains("parentPid"))
    }
}
