import Foundation
import Darwin

/// Queries only the bundled core, bounding output, wait time and cancellation before GUI feature gating.
enum CoreCapabilityProbe {
    static func read(binaryURL: URL? = nil) async throws -> Data {
        let process = Process(), pipe = Pipe()
        process.executableURL = binaryURL ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/hysteria")
        process.arguments = ["capabilities", "--output", "json"]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        try pipe.fileHandleForWriting.close()
        let reader = Task.detached(priority: .utility) { () throws -> Data in
            var data = Data()
            while let chunk = try pipe.fileHandleForReading.read(upToCount: 8192), !chunk.isEmpty {
                guard data.count + chunk.count <= 65_536 else { kill(process.processIdentifier, SIGKILL); throw ConfigurationError.invalid("核心能力报告过大。") }
                data.append(chunk)
            }
            return data
        }
        defer { try? pipe.fileHandleForReading.close() }
        do {
            let deadline = ContinuousClock.now + .seconds(5)
            while process.isRunning {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw ConfigurationError.invalid("核心能力检查超时。") }
                try await Task.sleep(for: .milliseconds(20))
            }
            let data = try await reader.value
            guard process.terminationStatus == 0 else {
                throw ConfigurationError.invalid("核心能力检查失败。")
            }
            return data
        } catch {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            _ = try? await reader.value
            throw error
        }
    }
}
