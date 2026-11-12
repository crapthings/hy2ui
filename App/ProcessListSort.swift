import Foundation

/// Identifies each sortable process-list value, including the two values within paired columns.
enum ProcessSortField {
    case pid, name, upload, download, sent, received
}

/// Cycles column sorting through both directions and the default name order with stable PID tie-breaking.
struct ProcessListSort {
    private(set) var field: ProcessSortField?
    private(set) var ascending = true

    mutating func select(_ next: ProcessSortField) {
        let initialAscending = next == .pid || next == .name
        if field != next {
            field = next
            ascending = initialAscending
        } else if ascending == initialAscending {
            ascending.toggle()
        } else {
            field = nil
            ascending = true
        }
    }

    func nextActionTitle(for field: ProcessSortField) -> String {
        var next = self
        next.select(field)
        guard next.field != nil else { return "恢复默认顺序" }
        return next.ascending ? "升序" : "降序"
    }

    func orderedIDs(in rows: [ProcessNetworkModel.Row], configuration: RoutingConfiguration) -> [UUID] {
        rows.sorted { left, right in
            let result: ComparisonResult
            switch field ?? .name {
            case .pid: result = compare(left.sample.pid, right.sample.pid)
            case .name: result = left.displayName.localizedStandardCompare(right.displayName)
            case .upload: result = compare(left.uploadRate, right.uploadRate)
            case .download: result = compare(left.downloadRate, right.downloadRate)
            case .sent: result = compare(left.sent, right.sent)
            case .received: result = compare(left.received, right.received)
            }
            if result == .orderedSame {
                if left.sample.pid != right.sample.pid { return left.sample.pid < right.sample.pid }
                return left.id.uuidString < right.id.uuidString
            }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }.map(\.id)
    }

    private func compare<Value: Comparable>(_ left: Value, _ right: Value) -> ComparisonResult {
        if left == right { return .orderedSame }
        return left < right ? .orderedAscending : .orderedDescending
    }
}
