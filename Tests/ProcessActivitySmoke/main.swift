import Foundation

/// Verifies stable list behavior using synthetic counters and monotonic times without launching nettop.
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
        var initialSort = ProcessListSort()
        initialSort.select(.download)
        model.sort(orderedIDs: initialSort.orderedIDs(in: model.rows, configuration: RoutingConfiguration()))
        precondition(model.rows.map { $0.sample.pid } == [2, 1])
        model.apply([sample(1, 10000), sample(2, 1001), sample(3, 1)], identities: [:], now: 4)
        precondition(model.rows.map { $0.sample.pid } == [1, 2, 3])
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

        let sortable = ProcessNetworkModel()
        let identities = [1: try identity(1, 10), 2: try identity(2, 10), 3: try identity(3, 10)] as [UInt32: ProcessIdentity]
        sortable.apply([sample(1, 100, name: "Alpha"), sample(2, 100, name: "Beta"), sample(3, 100, name: "Alpha")], identities: identities, now: 0)
        sortable.apply([sample(1, 120, 101, name: "Alpha"), sample(2, 180, 21, name: "Beta"), sample(3, 140, 101, name: "Alpha")], identities: identities, now: 2)
        var sorting = ProcessListSort()
        var configuration = RoutingConfiguration()
        func orderedPIDs() -> [UInt32] {
            let ids = sorting.orderedIDs(in: sortable.rows, configuration: configuration)
            return ids.map { id in sortable.rows.first { $0.id == id }!.sample.pid }
        }
        precondition(sorting.field == nil && orderedPIDs() == [1, 2, 3])
        sorting.select(.upload)
        precondition(orderedPIDs() == [1, 3, 2], "rate sorting must prefer the highest rate and break ties by PID")
        sorting.select(.upload)
        precondition(orderedPIDs() == [1, 2, 3], "selecting the same heading must reverse sort direction")
        precondition(sorting.nextActionTitle(for: .upload) == "恢复默认顺序")
        sorting.select(.upload)
        precondition(sorting.field == nil && orderedPIDs() == [1, 2, 3], "the third click must restore default name order")
        sorting.select(.upload)
        precondition(sorting.field == .upload && !sorting.ascending && orderedPIDs() == [1, 3, 2])
        sorting.select(.download)
        precondition(orderedPIDs() == [2, 3, 1], "upload and download need independent sorting")
        sorting.select(.received)
        precondition(orderedPIDs() == [2, 3, 1])
        sorting.select(.sent)
        precondition(orderedPIDs() == [1, 3, 2])
        sorting.select(.pid)
        precondition(orderedPIDs() == [1, 2, 3])
        sorting.select(.name)
        precondition(orderedPIDs() == [1, 2, 3], "name sorting must use displayed executable names rather than raw sampler labels")
        sorting.select(.name)
        precondition(!sorting.ascending && orderedPIDs() == [3, 2, 1])
        sorting.select(.name)
        precondition(sorting.field == nil && orderedPIDs() == [1, 2, 3], "text columns must also support the three-click cycle")
        sorting.select(.pid)
        let retainedIDs = Set(sortable.rows.map(\.id))
        sortable.sort(orderedIDs: sorting.orderedIDs(in: sortable.rows, configuration: configuration))
        precondition(sortable.rows.map { $0.sample.pid } == [1, 2, 3] && Set(sortable.rows.map(\.id)) == retainedIDs)
        sortable.beginInteraction()
        sortable.sort(orderedIDs: sortable.rows.reversed().map(\.id))
        precondition(sortable.rows.map { $0.sample.pid } == [1, 2, 3], "sorting during menu interaction must not move its target")
        sortable.endInteraction()
        print("Process column sorting, stable ties, selection, counter resets, menu tracking and PID reuse checks passed")
    }
}
