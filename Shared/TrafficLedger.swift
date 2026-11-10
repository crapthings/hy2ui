import Foundation

/// Stores upload and download totals with overflow-safe addition.
public struct TrafficTotals: Codable, Equatable, Sendable {
    public var upload: UInt64 = 0
    public var download: UInt64 = 0
    public var total: UInt64 { Self.adding(upload, download) }
    public init(upload: UInt64 = 0, download: UInt64 = 0) { self.upload = upload; self.download = download }
    public static func adding(_ left: UInt64, _ right: UInt64) -> UInt64 {
        let value = left.addingReportingOverflow(right)
        return value.overflow ? .max : value.partialValue
    }
}

/// Persists daily core transport totals independently from credentials and server profiles.
public struct TrafficLedger: Codable, Sendable {
    public private(set) var version = 1
    public private(set) var days: [String: TrafficTotals] = [:]
    public init() {}

    public mutating func record(upload: UInt64, download: UInt64, at date: Date, calendar: Calendar = .current) {
        let key = Self.key(date, calendar: calendar)
        let previous = days[key] ?? TrafficTotals()
        days[key] = TrafficTotals(upload: TrafficTotals.adding(previous.upload, upload),
                                  download: TrafficTotals.adding(previous.download, download))
        if days.count > 400 {
            for key in days.keys.sorted().prefix(days.count - 400) { days.removeValue(forKey: key) }
        }
    }

    public func today(at date: Date = Date(), calendar: Calendar = .current) -> TrafficTotals {
        days[Self.key(date, calendar: calendar)] ?? TrafficTotals()
    }

    public func month(at date: Date = Date(), calendar: Calendar = .current) -> TrafficTotals {
        let prefix = String(Self.key(date, calendar: calendar).prefix(7))
        return days.filter { $0.key.hasPrefix(prefix) }.values.reduce(TrafficTotals()) { result, next in
            TrafficTotals(upload: TrafficTotals.adding(result.upload, next.upload),
                          download: TrafficTotals.adding(result.download, next.download))
        }
    }

    private static func key(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

/// Rejects duplicate or decreasing samples and calculates deltas for one worker connection.
public struct TrafficAccumulator: Sendable {
    private var previous: CoreTelemetry?
    private var uptime: TimeInterval?
    public init() {}

    public mutating func consume(_ sample: CoreTelemetry, uptime arrival: TimeInterval) -> (totals: TrafficTotals, uploadRate: Double, downloadRate: Double)? {
        let now = sample.elapsedMicros.map { Double($0) / 1_000_000 } ?? arrival
        if let previous {
            guard previous.connection == sample.connection,
                  sample.upload >= previous.upload, sample.download >= previous.download,
                  now > (uptime ?? 0) else { return nil }
        }
        let totals = TrafficTotals(upload: sample.upload - (previous?.upload ?? 0),
                                   download: sample.download - (previous?.download ?? 0))
        let interval = uptime.map { now - $0 }
        previous = sample; uptime = now
        return (totals, interval.map { Double(totals.upload) / $0 } ?? 0,
                interval.map { Double(totals.download) / $0 } ?? 0)
    }
}
