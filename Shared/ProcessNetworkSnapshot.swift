import Foundation

/// Represents system-reported network counters for a process rather than proxy attribution.
public struct ProcessNetworkSample: Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let pid: UInt32
    public let received: UInt64
    public let sent: UInt64
    public init(id: String, name: String, pid: UInt32, received: UInt64, sent: UInt64) {
        self.id = id; self.name = name; self.pid = pid; self.received = received; self.sent = sent
    }
}

/// Parses only numeric per-process nettop columns and discards malformed or connection-detail rows.
public enum ProcessNetworkSnapshot {
    public static func parse(_ text: String) -> [ProcessNetworkSample] {
        var header: [String] = []
        var result: [String: ProcessNetworkSample] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = csv(String(line))
            if fields.first == "", fields.contains("bytes_in"), fields.contains("bytes_out") {
                header = fields; result.removeAll(keepingCapacity: true); continue
            }
            guard let receivedIndex = header.firstIndex(of: "bytes_in"),
                  let sentIndex = header.firstIndex(of: "bytes_out"), fields.count == header.count,
                  let label = fields.first, let split = label.lastIndex(of: "."),
                  let pid = UInt32(label[label.index(after: split)...]), pid > 0,
                  let received = UInt64(fields[receivedIndex]), let sent = UInt64(fields[sentIndex]) else { continue }
            let name = String(label[..<split])
            guard !name.isEmpty else { continue }
            result[label] = ProcessNetworkSample(id: label, name: name, pid: pid, received: received, sent: sent)
        }
        return Array(result.values)
    }

    private static func csv(_ line: String) -> [String] {
        var fields: [String] = [], current = "", quoted = false
        let characters = Array(line)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\"" {
                if quoted && index + 1 < characters.count && characters[index + 1] == "\"" {
                    current.append("\""); index += 1
                } else { quoted.toggle() }
            } else if character == "," && !quoted { fields.append(current); current = "" }
            else { current.append(character) }
            index += 1
        }
        guard !quoted else { return [] }
        fields.append(current)
        return fields
    }
}
