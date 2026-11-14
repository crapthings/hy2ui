import Foundation
import Darwin
import Observation

/// Samples physical Ethernet/Wi-Fi counters without summing tunnel and process counters a second time.
@MainActor @Observable
final class DashboardNetworkModel {
    private(set) var upload: Double = 0
    private(set) var download: Double = 0
    private(set) var sent: UInt64 = 0
    private(set) var received: UInt64 = 0
    private(set) var uploads: [Double] = []
    private(set) var downloads: [Double] = []
    private(set) var available = false
    private(set) var monthSent: UInt64 = 0
    private(set) var monthReceived: UInt64 = 0
    private var monthKey = ""

    private func recordMonth(sent: UInt64, received: UInt64) {
        let date = Calendar.current.dateComponents([.year, .month], from: Date())
        let key = "dashboard.physicalTraffic.v1.\(date.year ?? 0).\(date.month ?? 0)"
        if monthKey != key {
            monthKey = key
            monthSent = UInt64(UserDefaults.standard.string(forKey: key + ".sent") ?? "") ?? 0
            monthReceived = UInt64(UserDefaults.standard.string(forKey: key + ".received") ?? "") ?? 0
        }
        monthSent += sent; monthReceived += received
        if sent > 0 || received > 0 {
            UserDefaults.standard.set(String(monthSent), forKey: key + ".sent")
            UserDefaults.standard.set(String(monthReceived), forKey: key + ".received")
        }
    }

    func watch() async {
        recordMonth(sent: 0, received: 0)
        var previous: [String: (UInt64, UInt64)] = [:]
        var last = ProcessInfo.processInfo.systemUptime
        upload = 0; download = 0; sent = 0; received = 0; uploads = []; downloads = []
        defer { upload = 0; download = 0 }
        while !Task.isCancelled {
            var list: UnsafeMutablePointer<ifaddrs>?
            var counters: [String: (UInt64, UInt64)] = [:]
            available = getifaddrs(&list) == 0
            if let list {
                var cursor: UnsafeMutablePointer<ifaddrs>? = list
                while let entry = cursor {
                    let value = entry.pointee
                    let name = String(cString: value.ifa_name)
                    if name.hasPrefix("en"), value.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
                       value.ifa_flags & UInt32(IFF_UP) != 0, let data = value.ifa_data {
                        let stats = data.assumingMemoryBound(to: if_data.self).pointee
                        counters[name] = (UInt64(stats.ifi_obytes), UInt64(stats.ifi_ibytes))
                    }
                    cursor = value.ifa_next
                }
                freeifaddrs(list)
            }
            let now = ProcessInfo.processInfo.systemUptime
            var out: UInt64 = 0, incoming: UInt64 = 0
            for (name, value) in counters {
                if let old = previous[name] {
                    out += value.0 >= old.0 ? value.0 - old.0 : 0
                    incoming += value.1 >= old.1 ? value.1 - old.1 : 0
                }
            }
            let interval = max(0.001, now - last)
            upload = Double(out) / interval; download = Double(incoming) / interval
            sent += out; received += incoming
            recordMonth(sent: out, received: incoming)
            uploads = Array((uploads + [upload]).suffix(60))
            downloads = Array((downloads + [download]).suffix(60))
            previous = counters; last = now
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }
}
