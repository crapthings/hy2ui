import Foundation

/// Validates a bounded ordered list of user-selected HTTPS targets for manual network diagnostics.
enum DiagnosticTargets {
    static let key = "networkDiagnosticTargets.v1"
    static let defaults = "https://www.apple.com/library/test/success.html\nhttps://chatgpt.com/"
    static func parse(_ value: String) throws -> [String] {
        let lines = value.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard (1...4).contains(lines.count), Set(lines).count == lines.count else {
            throw ConfigurationError.invalid("请输入 1 至 4 个不同的 HTTPS 地址，每行一个。")
        }
        for line in lines {
            guard line.utf8.count <= 2048, !line.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  !line.contains(" "), let url = URLComponents(string: line), url.scheme?.lowercased() == "https",
                  let host = url.host, !host.isEmpty, url.user == nil, url.password == nil, url.fragment == nil,
                  url.port.map({ (1...65535).contains($0) }) ?? true else {
                throw ConfigurationError.invalid("诊断地址必须是有效 HTTPS URL，不能包含用户名、密码或片段。")
            }
        }
        return lines
    }
}
