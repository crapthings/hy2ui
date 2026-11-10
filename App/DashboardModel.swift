import Foundation
import Observation
#if SWIFT_PACKAGE
import Hy2Models
import Hy2Connection
#endif

/// Combines generation-scoped core samples with private daily accounting and live transfer rates.
@MainActor @Observable
final class DashboardModel {
    private(set) var ledger = TrafficLedger()
    private(set) var uploadRate = 0.0
    private(set) var downloadRate = 0.0
    private(set) var latencyMilliseconds: Double?
    private(set) var error: String?
    private(set) var now = Date()
    private let file: URL?
    private var writable = true
    private var dirty = false
    private var lastSave = ProcessInfo.processInfo.systemUptime
    @ObservationIgnored private var monitor: Task<Void, Never>?
    private var streams: [String: TrafficAccumulator] = [:]
    private var identifiers: [CoreTelemetrySource: (UUID, UInt64)] = [:]
    private var latest: [CoreTelemetrySource: LiveSample] = [:]

    /// Keeps transfer rates and latency valid only while a source continues reporting.
    private struct LiveSample {
        let time: TimeInterval
        let upload: Double
        let download: Double
        let latency: Double
    }

    var today: TrafficTotals { ledger.today(at: now) }
    var month: TrafficTotals { ledger.month(at: now) }

    init(file: URL? = nil) {
        self.file = file ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("Hy2UI/traffic.json")
        guard let file = self.file, FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let values = try file.resourceValues(forKeys: [.fileSizeKey])
            guard (values.fileSize ?? .max) <= 1_048_576 else { throw CocoaError(.fileReadCorruptFile) }
            ledger = try JSONDecoder().decode(TrafficLedger.self, from: Data(contentsOf: file))
            guard ledger.version == 1 else { throw CocoaError(.fileReadUnknown) }
        } catch {
            writable = false
            self.error = "无法读取流量记录，原文件已保留。"
        }
    }

    deinit { monitor?.cancel() }

    func start() {
        guard monitor == nil else { return }
        monitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self else { return }
                self.tick()
            }
        }
    }

    func receive(_ observation: CoreTelemetryObservation, source: CoreTelemetrySource) {
        let sample = observation.metrics
        if let previous = identifiers[source], previous.0 == observation.session,
           sample.connection < previous.1 { return }
        identifiers[source] = (observation.session, sample.connection)
        let key = "\(source.rawValue)/\(observation.session)/\(sample.connection)"
        let uptime = ProcessInfo.processInfo.systemUptime
        var accumulator = streams[key] ?? TrafficAccumulator()
        guard let delta = accumulator.consume(sample, uptime: uptime) else { return }
        // Each source needs only the active connection; core callbacks already reject stale worker generations.
        streams = streams.filter { !$0.key.hasPrefix(source.rawValue + "/") || $0.key == key }
        streams[key] = accumulator
        now = Date()
        ledger.record(upload: delta.totals.upload, download: delta.totals.download, at: now)
        dirty = dirty || delta.totals.total > 0
        latest[source] = LiveSample(time: uptime, upload: delta.uploadRate, download: delta.downloadRate,
                                    latency: Double(sample.rttMicros) / 1000)
        tick()
    }

    func clearLive() {
        latest.removeAll()
        uploadRate = 0; downloadRate = 0; latencyMilliseconds = nil
        flush()
    }

    func flush() {
        guard dirty, writable, let file else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(ledger).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            dirty = false; lastSave = ProcessInfo.processInfo.systemUptime; error = nil
        } catch { self.error = "流量记录保存失败。" }
    }

    private func tick() {
        now = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        let active = latest.filter { uptime - $0.value.time < 3 }
        uploadRate = active.values.reduce(0) { $0 + $1.upload }
        downloadRate = active.values.reduce(0) { $0 + $1.download }
        latencyMilliseconds = (active[.localTun] ?? active[.proxy]).map(\.latency)
        if uptime - lastSave >= 15 { flush() }
    }
}
