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
