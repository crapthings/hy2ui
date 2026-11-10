import Foundation
import Testing
@testable import Hy2Models

/// Verifies the copied command configures both environment conventions inside an isolated shell.
@Test func proxyCommandExportsLoopbackURLs() throws {
    let command = try #require(ShellProxyCommand.make(httpPort: 19080, socksPort: 12080))
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-f", "-c", command + "; /usr/bin/env"]
    process.environment = [:]
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    let lines = Set(String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init))
    for name in ["http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY"] {
        #expect(lines.contains("\(name)=http://127.0.0.1:19080"))
    }
    for name in ["all_proxy", "ALL_PROXY"] {
        #expect(lines.contains("\(name)=socks5h://127.0.0.1:12080"))
    }
}

/// Rejects invalid listener ports before offering a shell command to the clipboard.
@Test func proxyCommandRejectsInvalidPorts() {
    for ports in [(80, 11080), (18080, 0), (65536, 11080), (18080, 18080)] {
        #expect(ShellProxyCommand.make(httpPort: ports.0, socksPort: ports.1) == nil)
    }
}
