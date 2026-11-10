import Foundation

/// Formats transport counters and rates consistently without exposing unbounded numeric text.
enum TrafficFormatting {
    static func bytes(_ value: UInt64) -> String { format(Double(value)) }
    static func rate(_ value: Double) -> String { format(value) + "/s" }

    private static func format(_ value: Double) -> String {
        var count = max(value.isFinite ? value : 0, 0)
        let units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB"]
        var index = 0
        while count >= 1024 && index < units.count - 1 { count /= 1024; index += 1 }
        return String(format: index == 0 ? "%.0f %@" : "%.1f %@", count, units[index])
    }
}
