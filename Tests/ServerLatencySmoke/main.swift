import Foundation
import Darwin

/// Checks TCP latency success and failure using an ephemeral local listener without system network changes.
@main
private struct ServerLatencySmoke {
    static func main() async throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        precondition(descriptor >= 0)
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        precondition(result == 0 && listen(descriptor, 4) == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        precondition(named == 0)
        let port = Int(UInt16(bigEndian: address.sin_port))
        let latency = await ServerLatencyProbe.measure(host: "127.0.0.1", port: port)
        precondition(latency != nil && latency! > 0)
        let invalid = await ServerLatencyProbe.measure(host: "127.0.0.1", port: 65536)
        precondition(invalid == nil)
        print("Server latency loopback smoke passed.")
    }
}
