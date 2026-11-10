import Foundation
import Testing
@testable import Hy2Models

/// Rejects malformed telemetry and keeps byte counters separate from diagnostic text.
@Test func coreTelemetryIsBoundedAndNumeric() {
    let sample = CoreTelemetry.parse("HY2UI_METRICS 1 2048 4096 35000")
    #expect(sample == CoreTelemetry(connection: 1, upload: 2048, download: 4096, rttMicros: 35000))
    for line in ["HY2UI_METRICS 0 2 3 4", "HY2UI_METRICS 1 -2 3 4", "HY2UI_METRICS 1 2 3 600000001",
                 "HY2UI_METRICS 1 2 3 4 secret", "HY2UI_METRICS 1 2 3", "HY2UI_METRICS 1  2 3 4",
                 "HY2UI_METRICS 1 18446744073709551616 3 4"] {
        #expect(CoreTelemetry.parse(line) == nil)
    }
    var parser = CoreDiagnosticParser()
    parser.consume(Data("HY2UI_METRICS 1 20 30 400\nconnected to private-address\n".utf8))
    #expect(parser.drainTelemetry().count == 1)
    #expect(parser.drainTelemetry().isEmpty)
    #expect(parser.drain() == [.connected])
}

/// Calculates deltas once and rejects delayed samples and connection counter resets.
@Test func trafficAccumulatorDoesNotDoubleCount() throws {
    var accumulator = TrafficAccumulator()
    let firstValue = accumulator.consume(CoreTelemetry(connection: 1, upload: 100, download: 200, rttMicros: 10), uptime: 1)
    let first = try #require(firstValue)
    #expect(first.totals == TrafficTotals(upload: 100, download: 200))
    #expect(first.uploadRate == 0)
    let secondValue = accumulator.consume(CoreTelemetry(connection: 1, upload: 140, download: 280, rttMicros: 10), uptime: 3)
    let second = try #require(secondValue)
    #expect(second.totals == TrafficTotals(upload: 40, download: 80))
    #expect(second.uploadRate == 20 && second.downloadRate == 40)
    #expect(accumulator.consume(CoreTelemetry(connection: 1, upload: 120, download: 240, rttMicros: 10), uptime: 4) == nil)
    #expect(accumulator.consume(CoreTelemetry(connection: 2, upload: 1, download: 2, rttMicros: 10), uptime: 5) == nil)
    let duplicateValue = accumulator.consume(CoreTelemetry(connection: 1, upload: 140, download: 280, rttMicros: 10), uptime: 6)
    let duplicate = try #require(duplicateValue)
    #expect(duplicate.totals.total == 0)
}

/// Preserves calendar-day boundaries, month totals and saved history without overflow.
@Test func trafficHistorySurvivesMonthBoundary() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let january = try #require(calendar.date(from: DateComponents(year: 2026, month: 1, day: 31, hour: 23, minute: 59)))
    let february = try #require(calendar.date(from: DateComponents(year: 2026, month: 2, day: 1)))
    var ledger = TrafficLedger()
    ledger.record(upload: 100, download: 200, at: january, calendar: calendar)
    ledger.record(upload: 400, download: 800, at: february, calendar: calendar)
    let restored = try JSONDecoder().decode(TrafficLedger.self, from: JSONEncoder().encode(ledger))
    #expect(restored.today(at: january, calendar: calendar).total == 300)
    #expect(restored.month(at: february, calendar: calendar).total == 1200)
    #expect(restored.month(at: january, calendar: calendar).total == 300)
    #expect(TrafficTotals(upload: .max, download: 1).total == .max)
}

/// Reads only per-process counters while handling quoted names, column order and process exit between frames.
@Test func processNetworkCSVUsesLatestFrame() {
    let text = """
    ,bytes_out,bytes_in,
    obsolete.123,10,20,
    ,bytes_in,bytes_out,
    "App, Helper.456",100,50,
    broken.999,not-a-number,30,
    tcp4 127.0.0.1:1<->127.0.0.1:2,20,30,

    """
    let result = ProcessNetworkSnapshot.parse(text)
    #expect(result == [ProcessNetworkSample(id: "App, Helper.456", name: "App, Helper", pid: 456, received: 100, sent: 50)])
}

/// Uses core sampling time rather than delivery time so batched IPC does not inflate transfer rates.
@Test func trafficRateUsesMonotonicCoreTime() throws {
    var accumulator = TrafficAccumulator()
    _ = accumulator.consume(CoreTelemetry(connection: 1, upload: 100, download: 200, rttMicros: 10, elapsedMicros: 0), uptime: 100)
    let value = accumulator.consume(CoreTelemetry(connection: 1, upload: 300, download: 600, rttMicros: 10, elapsedMicros: 2_000_000), uptime: 100.001)
    let delta = try #require(value)
    #expect(delta.uploadRate == 100 && delta.downloadRate == 200)
}
