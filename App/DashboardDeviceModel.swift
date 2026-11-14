import Foundation
import Darwin
import Observation

/// Reads physical IPv4 addresses and resident memory for this app and its verified core processes.
@MainActor @Observable
final class DashboardDeviceModel {
    private(set) var addresses: [String] = []
    private(set) var appMemory: UInt64?
    private(set) var coreMemory: UInt64?

    func watch(model: AppModel) async {
        while !Task.isCancelled {
            addresses = Self.localAddresses()
            appMemory = Self.memory(pid: getpid())
            var pids = Set<Int32>()
            var children = [Int32](repeating: 0, count: 1024)
            let size = children.withUnsafeMutableBytes { proc_listchildpids(getpid(), $0.baseAddress, Int32($0.count)) }
            if size > 0 {
                for pid in children.prefix(Int(size) / MemoryLayout<Int32>.size) where pid > 0 {
                    var buffer = [CChar](repeating: 0, count: 4096)
                    let count = proc_pidpath(pid, &buffer, UInt32(buffer.count))
                    if count > 0, String(cString: buffer) == Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/hysteria").path {
                        pids.insert(pid)
                    }
                }
            }
            let identity = model.interfaceSession?.process
            let unverifiedCore = identity.map { !$0.isCurrent } ?? false
            if let identity, identity.isCurrent { pids.insert(Int32(identity.pid)) }
            let samples = pids.map { Self.memory(pid: $0) }
            coreMemory = unverifiedCore || samples.contains(where: { $0 == nil }) ? nil : samples.compactMap { $0 }.reduce(0, +)
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }

    private static func memory(pid: Int32) -> UInt64? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        return info.pti_resident_size
    }

    private static func localAddresses() -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let list else { return [] }
        defer { freeifaddrs(list) }
        var result: [String] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = list
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let value = entry.pointee
            guard String(cString: value.ifa_name).hasPrefix("en"), value.ifa_flags & UInt32(IFF_UP) != 0,
                  let address = value.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                result.append(String(cString: buffer))
            }
        }
        return Array(Set(result)).sorted()
    }
}
