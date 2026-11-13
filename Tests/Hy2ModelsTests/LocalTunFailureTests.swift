import Foundation
import Testing
@testable import Hy2Models

/// Preserves structured exit metadata while accepting lifecycle events from an older helper.
@Test func helperFailureWireCompatibility() throws {
    let legacy = try JSONDecoder().decode(LocalTunEvent.self, from: Data(#"{"kind":"error","message":"old failure"}"#.utf8))
    #expect(legacy.failure == nil)
    let failure = LocalTunFailure(.workerExited, exitStatus: 9, terminatedBySignal: true)
    let event = LocalTunEvent(kind: .error, failure: failure)
    let data = try JSONEncoder().encode(event)
    let decoded = try JSONDecoder().decode(LocalTunEvent.self, from: data)
    #expect(decoded.failure?.code == .workerExited)
    #expect(decoded.failure?.exitStatus == 9 && decoded.failure?.terminatedBySignal == true)
}

/// Stores diagnostic timestamps and fixed failure metadata without accepting free-form worker output.
@Test func helperDiagnosticRecordContainsOnlySafeMetadata() throws {
    let failure = LocalTunFailure(.startupFailed, exitStatus: 1)
    let data = try JSONEncoder().encode(LocalTunDiagnosticRecord(failure: failure, timestamp: Date(timeIntervalSince1970: 0)))
    let value = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(value.keys) == ["timestamp", "failure"])
    let fields = try #require(value["failure"] as? [String: Any])
    #expect(Set(fields.keys) == ["code", "exitStatus", "terminatedBySignal"])
    #expect(failure.diagnostic.contains("exit=1"))
}

/// Translates failure messages while leaving numeric diagnostic metadata unchanged.
@Test func localizedHelperFailureKeepsDiagnosticFields() {
    let value = LocalTunFailure(.recoveryFailed, exitStatus: 9, terminatedBySignal: true).diagnostic
    let translated = AppLocalization.text(value, language: .english)
    #expect(translated.hasPrefix("Service network recovery failed."))
    #expect(translated.contains("[code=recoveryFailed, exit=9, signal=true]"))
}

/// Promotes only the core's allowlisted failure category, never raw stderr values.
@Test func captureConflictDiagnosticRemainsAvailableAfterDrain() {
    var parser = CoreDiagnosticParser()
    parser.consume(Data("error: ambiguous route [capture_".utf8))
    #expect(parser.startupFailure == nil)
    parser.consume(Data("conflict]\n".utf8))
    #expect(parser.startupFailure == .captureConflict)
    _ = parser.drain()
    #expect(parser.startupFailure == .captureConflict)
    var ignored = CoreDiagnosticParser()
    ignored.consume(Data("caller text [capture_conflict]\n".utf8))
    #expect(ignored.startupFailure == nil)
}

/// Recognizes every documented core category without exposing untrusted error text.
@Test func coreFailureCategoriesPreserveOnlySafeDetails() throws {
    for category in LocalTunCoreFailure.allCases {
        var parser = CoreDiagnosticParser()
        parser.consume(Data("error: password=secret peer-controlled text [\(category.rawValue)]\n".utf8))
        #expect(parser.coreFailure == category)
        let failure = LocalTunFailure(.startupFailed, exitStatus: 1, coreFailure: parser.coreFailure)
        #expect(failure.diagnostic.contains(category.rawValue))
        #expect(!failure.diagnostic.contains("secret"))
        let restored = try JSONDecoder().decode(LocalTunFailure.self, from: JSONEncoder().encode(failure))
        #expect(restored.coreFailure == category)
    }
    var parser = CoreDiagnosticParser()
    parser.consume(Data("error: secret [unknown_code]\npeer says [configuration_parse]\n".utf8))
    #expect(parser.coreFailure == nil)
    let legacy = try JSONDecoder().decode(LocalTunFailure.self, from: Data(#"{"code":"startupFailed","exitStatus":1,"terminatedBySignal":false}"#.utf8))
    #expect(legacy.coreFailure == nil)
}

/// Identifies local route failures without retaining credentials, endpoints, or arbitrary error text.
@Test func localRouteFailureDetailsAreBoundedAndSafe() throws {
    var parser = CoreDiagnosticParser()
    parser.consume(Data("error: failed to add TUN route secret-server-address: Network is unreachable (os error 51) [tun_routes]\n".utf8))
    #expect(parser.coreReason?.contains("向内核添加路由") == true)
    #expect(parser.coreReason?.contains("errno=51") == true)
    #expect(parser.coreReason?.contains("secret-server-address") == false)
    var journal = CoreDiagnosticParser()
    journal.consume(Data("error: cannot acquire TUN route journal: journal ancestor ownership or permissions are unsafe [tun_routes]\n".utf8))
    #expect(journal.coreReason?.contains("上级目录") == true)
    var receipt = CoreDiagnosticParser()
    receipt.consume(Data("error: added route identity could not be verified [tun_routes]\n".utf8))
    #expect(receipt.coreReason?.contains("身份与预期不一致") == true)
    var remote = CoreDiagnosticParser()
    remote.consume(Data("error: failed to add TUN route password=secret (os error 51) [connection_failed]\n".utf8))
    #expect(remote.coreReason == nil)
    let failure = LocalTunFailure(.startupFailed, coreFailure: .tunRoutes, coreReason: parser.coreReason)
    let decoded = try JSONDecoder().decode(LocalTunFailure.self, from: JSONEncoder().encode(failure))
    #expect(decoded.coreReason == failure.coreReason)
    #expect(decoded.diagnostic.contains("errno=51"))
}

/// Retains validated route identity while discarding arbitrary interface names and trailing messages.
@Test func duplicateRouteDiagnosticIncludesValidatedIdentity() {
    var parser = CoreDiagnosticParser()
    parser.consume(Data("error: failed to add TUN route Route { destination: 203.0.113.8/32, gateway: 192.168.1.1, if_index: 19, if_name: secret-password }: File exists (os error 17) [tun_routes]\n".utf8))
    #expect(parser.coreReason?.contains("203.0.113.8/32") == true)
    #expect(parser.coreReason?.contains("192.168.1.1") == true)
    #expect(parser.coreReason?.contains("接口索引：19") == true)
    #expect(parser.coreReason?.contains("secret-password") == false)
}

/// Distinguishes interface readiness from remote authentication without accepting local readiness alone.
@Test func tunStartupReadinessPhasesAreIndependent() {
    var parser = CoreDiagnosticParser()
    parser.consume(Data("TUN proxy listening on interface utun123\n".utf8))
    #expect(parser.nativeInterfaceReady)
    #expect(!parser.serverAuthenticated)
    #expect(!parser.ready)
    parser.consume(Data("connected to 192.0.2.1:443 (UDP relay: true)\n".utf8))
    #expect(parser.serverAuthenticated && parser.ready)
}
