import Foundation

/// Measures authenticated Hy2 QUIC RTT in a disposable worker without changing system networking.
@MainActor
enum ServerLatencyProbe {
    static func measure(configuration: Data, credentials: Credentials, binaryURL: URL? = nil) async -> Int? {
        let worker = CoreProcess(binaryURL: binaryURL)
        var sample: CoreTelemetry?
        worker.onTelemetry = { sample = $0.metrics }
        do {
            var core = try JSONSerialization.jsonObject(with: configuration) as? [String: Any] ?? [:]
            core = core.filter { ["server", "auth", "tls", "obfs", "quic", "congestion", "bandwidth"].contains($0.key) }
            core["lazy"] = false
            core["socks5"] = ["listen": "127.0.0.1:0"]
            core["http"] = ["listen": "127.0.0.1:0"]
            let data = try JSONSerialization.data(withJSONObject: core)
            try await worker.start(configuration: data, credentials: credentials)
            let deadline = ContinuousClock.now + .seconds(2)
            while sample == nil && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(25))
            }
            let result = sample.map { max(1, Int(($0.rttMicros + 999) / 1000)) }
            await worker.stop()
            return result
        } catch {
            await worker.stop()
            return nil
        }
    }
}
