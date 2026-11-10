import Foundation

/// Verifies that latency comes from core QUIC telemetry and stops the disposable worker on cancellation.
@main
private struct ServerLatencySmoke {
    @MainActor
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("mock-core")
        let script = """
        #!/bin/sh
        cat >/dev/null
        printf '%s\\n' 'connected to loopback' 'SOCKS5 proxy listening on loopback' 'HTTP proxy listening on loopback' 'HY2UI_METRICS 1 10 20 34800 1000000' >&2
        trap 'exit 0' INT TERM
        while :; do /bin/sleep 0.05; done
        """
        try script.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let data = Data("{\"server\":\"localhost:443\",\"auth\":\"test-only\"}".utf8)
        let measured = await ServerLatencyProbe.measure(configuration: data, credentials: Credentials(), binaryURL: binary)
        precondition(measured == 35)
        let task = Task { await ServerLatencyProbe.measure(configuration: data, credentials: Credentials(), binaryURL: binary) }
        task.cancel()
        let cancelled = await task.value
        precondition(cancelled == nil)
        print("Server latency QUIC telemetry and cancellation smoke passed.")
    }
}
