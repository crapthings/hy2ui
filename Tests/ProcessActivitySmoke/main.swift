import Foundation

/// Verifies stable table behavior using synthetic counters and monotonic times without launching nettop.
@main struct ProcessActivitySmoke {
    @MainActor static func main() throws {
        func sample(_ pid: UInt32, _ received: UInt64, _ sent: UInt64 = 1, name: String? = nil) -> ProcessNetworkSample {
            ProcessNetworkSample(id: "\(name ?? String(pid)).\(pid)", name: name ?? String(pid), pid: pid, received: received, sent: sent)
        }
        func identity(_ pid: UInt32, _ start: UInt64) throws -> ProcessIdentity {
            ProcessIdentity(pid: pid, startSeconds: start, startMicroseconds: 0, target: try ProcessRoutingTarget(path: "/test/process\(pid)"))
        }
        let model = ProcessNetworkModel()
        model.apply([sample(2, 200), sample(1, 100)], identities: [:], now: 0)
        let firstIDs = model.rows.map(\.id)
        precondition(model.rows.map { $0.sample.pid } == [1, 2] && model.rows.allSatisfy { $0.downloadRate == 0 })
        model.apply([sample(2, 1000), sample(1, 110)], identities: [:], now: 2)
        precondition(model.rows.map(\.id) == firstIDs && model.rows[1].downloadRate == 400)
        model.sort(using: [KeyPathComparator(\ProcessNetworkModel.Row.downloadRate, order: .reverse)])
        precondition(model.rows.map { $0.sample.pid } == [2, 1])
        model.apply([sample(1, 10000), sample(2, 1001), sample(3, 1)], identities: [:], now: 4)
        precondition(model.rows.map { $0.sample.pid } == [2, 1, 3])
        model.apply([sample(1, 1), sample(2, 1001), sample(3, 1)], identities: [:], now: 6)
        precondition(model.rows.first { $0.sample.pid == 1 }!.downloadRate == 0)

        let gap = ProcessNetworkModel()
        gap.apply([sample(1, 100)], identities: [:], now: 0)
        let gapID = gap.rows[0].id
        gap.apply([], identities: [:], now: 2)
        precondition(gap.rows[0].id == gapID && !gap.rows[0].isPresent && gap.rows[0].downloadRate == 0)
        gap.apply([sample(1, 1000)], identities: [:], now: 4)
        precondition(gap.rows[0].id == gapID && gap.rows[0].downloadRate == 0)
        gap.apply([sample(1, 1200)], identities: [:], now: 6)
        precondition(gap.rows[0].downloadRate == 100)
        gap.retain([gapID]); gap.apply([], identities: [:], now: 30)
        precondition(gap.rows.count == 1)
        gap.retain([]); precondition(gap.rows.isEmpty)

        let menu = ProcessNetworkModel()
        menu.apply([sample(1, 100)], identities: [:], now: 0)
        menu.beginInteraction(); menu.beginInteraction()
        menu.apply([sample(2, 100)], identities: [:], now: 20)
        precondition(menu.rows.count == 1 && menu.rows[0].sample.pid == 1 && !menu.rows[0].isPresent)
        menu.endInteraction(); precondition(menu.rows[0].sample.pid == 1)
        menu.endInteraction(); precondition(menu.rows.count == 1 && menu.rows[0].sample.pid == 2)

        let reuse = ProcessNetworkModel()
        reuse.apply([sample(1, 100)], identities: [1: try identity(1, 10)], now: 0)
        let oldID = reuse.rows[0].id
        reuse.retain([oldID])
        reuse.apply([sample(1, 200)], identities: [:], now: 2)
        precondition(reuse.rows[0].id == oldID && reuse.rows[0].identity == nil)
        reuse.apply([sample(1, 300)], identities: [1: try identity(1, 20)], now: 4)
        precondition(reuse.rows.count == 2 && reuse.rows[0].id == oldID && !reuse.rows[0].isPresent)
        precondition(reuse.rows[1].id != oldID && reuse.rows[1].downloadRate == 0)
        reuse.apply([sample(1, 400)], identities: [1: try identity(1, 20)], now: 20)
        precondition(reuse.rows.count == 2)
        reuse.retain([]); precondition(reuse.rows.count == 1 && reuse.rows[0].id != oldID)

        let paused = ProcessNetworkModel()
        paused.apply([sample(1, 100)], identities: [:], now: 0)
        paused.apply([sample(1, 200)], identities: [:], now: 2)
        paused.setPaused(true)
        paused.apply([sample(1, 1000)], identities: [:], now: 20)
        precondition(paused.rows[0].sample.received == 200 && paused.rows[0].downloadRate == 50)
        paused.setPaused(false)
        paused.apply([sample(1, 1200)], identities: [:], now: 22)
        precondition(paused.rows[0].downloadRate == 0)
        paused.apply([sample(1, 1400)], identities: [:], now: 24)
        precondition(paused.rows[0].downloadRate == 100)
        print("Stable order, explicit sort, counter reset, missing rows, selection, menu tracking, PID reuse and pause/resume checks passed")
    }
}
