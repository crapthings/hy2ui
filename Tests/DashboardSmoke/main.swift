import Foundation

/// Checks persistence, connection resets and stale samples without touching live profiles or network settings.
@main
private struct DashboardSmoke {
    @MainActor
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("traffic.json")
        let model = DashboardModel(file: file)
        let session = UUID()
        model.receive(CoreTelemetryObservation(session: session, metrics: CoreTelemetry(connection: 1, upload: 100, download: 200, rttMicros: 35000)), source: .localTun)
        model.receive(CoreTelemetryObservation(session: session, metrics: CoreTelemetry(connection: 1, upload: 140, download: 260, rttMicros: 35000)), source: .localTun)
        model.receive(CoreTelemetryObservation(session: session, metrics: CoreTelemetry(connection: 1, upload: 140, download: 260, rttMicros: 35000)), source: .localTun)
        precondition(model.today.total == 400)
        model.receive(CoreTelemetryObservation(session: session, metrics: CoreTelemetry(connection: 2, upload: 10, download: 20, rttMicros: 40000)), source: .localTun)
        model.receive(CoreTelemetryObservation(session: session, metrics: CoreTelemetry(connection: 1, upload: 900, download: 900, rttMicros: 35000)), source: .localTun)
        precondition(model.today.total == 430 && model.latencyMilliseconds == 40)
        model.receive(CoreTelemetryObservation(session: UUID(), metrics: CoreTelemetry(connection: 1, upload: 5, download: 10, rttMicros: 30000)), source: .localTun)
        model.receive(CoreTelemetryObservation(session: UUID(), metrics: CoreTelemetry(connection: 1, upload: 7, download: 9, rttMicros: 35000)), source: .proxy)
        precondition(model.today.total == 461)
        model.clearLive()
        precondition(model.uploadRate == 0 && model.downloadRate == 0 && model.latencyMilliseconds == nil)
        let restored = DashboardModel(file: file)
        precondition(restored.today.total == 461 && restored.error == nil)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        precondition(permissions?.intValue == 0o600)
        let future = Data("{\"version\":99,\"days\":{}}".utf8)
        try future.write(to: file)
        let unsupported = DashboardModel(file: file)
        unsupported.receive(CoreTelemetryObservation(session: UUID(), metrics: CoreTelemetry(connection: 1, upload: 10, download: 20, rttMicros: 3)), source: .localTun)
        unsupported.flush()
        let preserved = try Data(contentsOf: file)
        precondition(unsupported.error != nil && preserved == future)
        print("Dashboard persistence, mixed-source accounting, stale sample and future-version checks passed.")
    }
}
