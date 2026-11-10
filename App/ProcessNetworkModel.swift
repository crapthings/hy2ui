import Foundation
import Observation

/// Samples system process activity only while its view is open without changing network settings.
@MainActor @Observable
final class ProcessNetworkModel {
    /// Keeps a stable presentation identity while displaying the latest available process counters.
    struct Row: Identifiable {
        let id: UUID
        let sample: ProcessNetworkSample
        let identity: ProcessIdentity?
        let downloadRate: Double
        let uploadRate: Double
        let isPresent: Bool
        let displayName: String
        var received: UInt64 { sample.received }
        var sent: UInt64 { sample.sent }
    }
    /// Retains one observation and baseline independently from its position in the table.
    private struct Entry {
        var sample: ProcessNetworkSample
        var identity: ProcessIdentity?
        var lastKnownIdentity: ProcessIdentity?
        var lastSeen: TimeInterval
        var baselineTime: TimeInterval?
        var downloadRate: Double = 0
        var uploadRate: Double = 0
        var isPresent = true
        var displayName: String { identity.map { URL(fileURLWithPath: $0.target.path).lastPathComponent } ?? sample.name }
    }
    private(set) var rows: [Row] = []
    private(set) var error: String?
    private(set) var isPaused = false
    private var entries: [UUID: Entry] = [:]
    private var byPID: [UInt32: UUID] = [:]
    private var order: [UUID] = []
    private var retained: Set<UUID> = []
    private var interactionDepth = 0
    private var watchGeneration = UUID()
    private var samplingGeneration = UUID()
    private var lastNow: TimeInterval = 0

    func watch() async {
        let generation = UUID(); watchGeneration = generation
        resetBaselines()
        while !Task.isCancelled && watchGeneration == generation {
            if !isPaused {
                let sampleToken = samplingGeneration
                let result = await Task.detached(priority: .utility) { Self.snapshot() }.value
                guard !Task.isCancelled, watchGeneration == generation else { return }
                if !isPaused && sampleToken == samplingGeneration {
                    switch result {
                    case .success(let snapshot): apply(snapshot.samples, identities: snapshot.identities, now: ProcessInfo.processInfo.systemUptime)
                    case .failure: error = "系统网络活动暂时不可用。"
                    }
                }
            }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }

    func setPaused(_ value: Bool) {
        guard value != isPaused else { return }
        isPaused = value; samplingGeneration = UUID()
        resetBaselines()
    }
    func retain(_ ids: Set<UUID>) { retained = ids; publish() }
    func beginInteraction() { interactionDepth += 1 }
    func endInteraction() { interactionDepth = max(0, interactionDepth - 1); publish() }
    func endInteractions() { interactionDepth = 0; publish() }

    func sort(using comparators: [KeyPathComparator<Row>]) {
        guard interactionDepth == 0 else { return }
        let sorted = rows.sorted(using: comparators).map(\.id)
        let visible = Set(sorted)
        order = sorted + order.filter { !visible.contains($0) }
        publish()
    }

    func apply(_ samples: [ProcessNetworkSample], identities: [UInt32: ProcessIdentity], now: TimeInterval) {
        guard !isPaused else { return }
        lastNow = now
        for id in entries.keys { entries[id]?.isPresent = false }
        var added: [UUID] = []
        for sample in samples where sample.received > 0 || sample.sent > 0 {
            let identity = identities[sample.pid]
            var id = byPID[sample.pid]
            if let existing = id.flatMap({ entries[$0] }), let before = existing.lastKnownIdentity, let after = identity,
               (before.startSeconds != after.startSeconds || before.startMicroseconds != after.startMicroseconds) { id = nil }
            if let id, var entry = entries[id] {
                let prior = entry.sample
                if let interval = entry.baselineTime.map({ now - $0 }), interval > 0 {
                    entry.downloadRate = sample.received >= prior.received ? Double(sample.received - prior.received) / interval : 0
                    entry.uploadRate = sample.sent >= prior.sent ? Double(sample.sent - prior.sent) / interval : 0
                } else { entry.downloadRate = 0; entry.uploadRate = 0 }
                if let identity { entry.lastKnownIdentity = identity }
                entry.sample = sample; entry.identity = identity; entry.lastSeen = now; entry.baselineTime = now; entry.isPresent = true
                entries[id] = entry
            } else {
                let id = UUID()
                entries[id] = Entry(sample: sample, identity: identity, lastKnownIdentity: identity, lastSeen: now, baselineTime: now)
                byPID[sample.pid] = id; added.append(id)
            }
        }
        // Only newly discovered rows are sorted; existing positions are independent of sampling order.
        added.sort { left, right in
            guard let left = entries[left], let right = entries[right] else { return false }
            return (left.displayName, left.sample.pid) < (right.displayName, right.sample.pid)
        }
        order.append(contentsOf: added)
        for id in entries.keys where entries[id]?.isPresent == false {
            entries[id]?.downloadRate = 0; entries[id]?.uploadRate = 0; entries[id]?.baselineTime = nil
        }
        error = nil; publish()
    }

    private func resetBaselines() {
        for id in entries.keys { entries[id]?.baselineTime = nil }
    }
    private func publish() {
        if interactionDepth == 0 && !isPaused {
            let expired = entries.filter { !$0.value.isPresent && lastNow - $0.value.lastSeen >= 10 && !retained.contains($0.key) }.map(\.key)
            for id in expired {
                if let pid = entries[id]?.sample.pid, byPID[pid] == id { byPID.removeValue(forKey: pid) }
                entries.removeValue(forKey: id)
            }
            order.removeAll { entries[$0] == nil }
        }
        let visible = interactionDepth > 0 ? rows.map(\.id) : order
        rows = visible.compactMap { id in
            guard let entry = entries[id] else { return nil }
            return Row(id: id, sample: entry.sample, identity: entry.identity, downloadRate: entry.downloadRate,
                       uploadRate: entry.uploadRate, isPresent: entry.isPresent, displayName: entry.displayName)
        }
    }

    nonisolated private static func snapshot() -> Result<(samples: [ProcessNetworkSample], identities: [UInt32: ProcessIdentity]), Error> {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = ["-P", "-L", "1", "-x", "-n", "-J", "bytes_in,bytes_out"]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
                if process.isRunning { process.terminate() }
            }
            var data = Data()
            while let chunk = try output.fileHandleForReading.read(upToCount: 8192), !chunk.isEmpty {
                guard data.count + chunk.count <= 1_048_576 else {
                    process.terminate(); process.waitUntilExit()
                    return .failure(CocoaError(.fileReadTooLarge))
                }
                data.append(chunk)
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return .failure(CocoaError(.fileReadUnknown)) }
            let samples = ProcessNetworkSnapshot.parse(String(decoding: data, as: UTF8.self))
            let identities = samples.compactMap { ProcessIdentity.read(pid: $0.pid) }
            return .success((samples, Dictionary(identities.map { ($0.pid, $0) }, uniquingKeysWith: { _, last in last })))
        } catch { return .failure(error) }
    }
}
