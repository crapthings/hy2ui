import Foundation
import Darwin

/// Captures bounded installer output while the authorization process runs outside the UI actor.
private final class InstallerOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        bytes.append(data.prefix(max(0, 65_536 - bytes.count)))
    }
    func text() -> String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Requests the native macOS administrator dialog without collecting or storing its password.
enum HelperInstallerAuthorization {
    static func run(script: String) async throws {
        try Task.checkCancellation()
        // An authorized transaction must finish rather than being killed midway through DNS recovery.
        try await Task.detached(priority: .userInitiated) { try execute(script: script) }.value
    }

    private static func execute(script: String) throws {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        let stdout = InstallerOutput()
        let stderr = InstallerOutput()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "AppleScript"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        defer {
            for handle in [input.fileHandleForReading, input.fileHandleForWriting,
                           output.fileHandleForReading, output.fileHandleForWriting,
                           errors.fileHandleForReading, errors.fileHandleForWriting] { try? handle.close() }
        }
        try process.run()
        try input.fileHandleForReading.close()
        try output.fileHandleForWriting.close()
        try errors.fileHandleForWriting.close()
        let readers = DispatchGroup()
        drain(output.fileHandleForReading, into: stdout, group: readers)
        drain(errors.fileHandleForReading, into: stderr, group: readers)
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()
            readers.wait()
            throw HelperInstallationError.failed("无法安全创建后台安装请求。")
        }
        do { try input.fileHandleForWriting.write(contentsOf: Data(script.utf8)) }
        catch {
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()
            readers.wait()
            throw error
        }
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        readers.wait()
        if stdout.text() == HelperInstallationCommand.cancellationMarker { throw HelperInstallationError.cancelled }
        guard process.terminationStatus == 0 else {
            let detail = stderr.text()
            throw HelperInstallationError.failed(detail.isEmpty ? "后台操作失败，请重试。" : String(detail.prefix(2000)))
        }
    }

    private static func drain(_ handle: FileHandle, into output: InstallerOutput, group: DispatchGroup) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { group.leave() }
            do {
                while let data = try handle.read(upToCount: 4096), !data.isEmpty { output.append(data) }
            } catch { /* The process exit status still reports installer failure without leaking request data. */ }
        }
    }
}
