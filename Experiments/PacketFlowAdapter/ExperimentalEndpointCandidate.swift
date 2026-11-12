import Foundation
import Darwin

/// Describes a narrow numeric server candidate without claiming that its socket is protected.
struct ExperimentalEndpointCandidate: Equatable {
    let address: String
    let port: UInt16
    let family: Int32
    let tlsServerName: String
    var exclusionPrefixLength: Int { family == Int32(AF_INET) ? 32 : 128 }

    init(server: String, tlsServerName: String) throws {
        guard server == server.trimmingCharacters(in: .whitespacesAndNewlines),
              !tlsServerName.isEmpty, tlsServerName.utf8.count <= 253,
              tlsServerName.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) }) else {
            throw ExperimentalEndpointError.invalidAddress
        }
        let host: String
        let portText: String
        let addressFamily: Int32
        if server.hasPrefix("[") {
            guard let end = server.firstIndex(of: "]"), server.index(after: end) < server.endIndex,
                  server[server.index(after: end)] == ":" else { throw ExperimentalEndpointError.invalidAddress }
            host = String(server[server.index(after: server.startIndex)..<end])
            portText = String(server[server.index(end, offsetBy: 2)...])
            addressFamily = Int32(AF_INET6)
        } else {
            let parts = server.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2 else { throw ExperimentalEndpointError.invalidAddress }
            host = String(parts[0])
            portText = String(parts[1])
            addressFamily = Int32(AF_INET)
        }
        guard !portText.isEmpty, portText.utf8.allSatisfy({ (48...57).contains($0) }),
              let port = UInt16(portText), port > 0 else { throw ExperimentalEndpointError.invalidAddress }
        var addressBuffer = [UInt8](repeating: 0, count: addressFamily == Int32(AF_INET) ? 4 : 16)
        let parsed = host.withCString { source in
            addressBuffer.withUnsafeMutableBytes { inet_pton(addressFamily, source, $0.baseAddress) }
        }
        guard parsed == 1, Self.isCandidateUnicast(addressBuffer, family: addressFamily) else {
            throw ExperimentalEndpointError.invalidAddress
        }
        var printable = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let rendered = addressBuffer.withUnsafeBytes { source in
            inet_ntop(addressFamily, source.baseAddress, &printable, socklen_t(printable.count))
        }
        guard rendered != nil else { throw ExperimentalEndpointError.invalidAddress }
        self.address = String(cString: printable)
        self.port = port
        self.family = addressFamily
        self.tlsServerName = tlsServerName
    }

    private static func isCandidateUnicast(_ bytes: [UInt8], family: Int32) -> Bool {
        if family == Int32(AF_INET) {
            return bytes[0] != 0 && bytes[0] != 127 && bytes[0] < 224
                && !(bytes[0] == 169 && bytes[1] == 254)
                && !(bytes[0] == 198 && (bytes[1] == 18 || bytes[1] == 19))
        }
        let firstTwelveZero = bytes.prefix(12).allSatisfy { $0 == 0 }
        let mappedV4 = bytes.prefix(10).allSatisfy { $0 == 0 } && bytes[10] == 0xff && bytes[11] == 0xff
        let linkLocal = bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80
        return !firstTwelveZero && !mappedV4 && bytes[0] != 0xff && !linkLocal
    }
}

/// Identifies endpoint inputs that do not satisfy the narrow static experiment profile.
enum ExperimentalEndpointError: Error, Equatable { case invalidAddress }
