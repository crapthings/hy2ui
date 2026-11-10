import Foundation
import Darwin

/// Captures executable identity and process start time so stale activity rows cannot create rules for reused PIDs.
struct ProcessIdentity: Equatable, Sendable {
    let pid: UInt32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
    let target: ProcessRoutingTarget

    static func read(pid: UInt32) -> ProcessIdentity? {
        guard pid > 0, pid <= UInt32(Int32.max) else { return nil }
        func started() -> (UInt64, UInt64)? {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
            guard proc_pidinfo(Int32(pid), PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
            return (info.pbi_start_tvsec, info.pbi_start_tvusec)
        }
        guard let before = started() else { return nil }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let count = buffer.withUnsafeMutableBytes { proc_pidpath(Int32(pid), $0.baseAddress, UInt32($0.count)) }
        guard count > 0, let after = started(), before == after,
              let target = try? ProcessRoutingTarget(path: String(cString: buffer)) else { return nil }
        return ProcessIdentity(pid: pid, startSeconds: before.0, startMicroseconds: before.1, target: target)
    }

    var isCurrent: Bool { Self.read(pid: pid) == self }
}
