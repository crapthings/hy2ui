import Foundation
import Darwin

/// Rejects privileged inputs whose ownership or permissions permit replacement by ordinary users.
enum TrustedInstallation {
    static func requireRoot() throws {
        guard geteuid() == 0 else { throw HelperFailure("本地增强模式服务必须由管理员安装后运行。") }
    }

    static func validate() throws {
        try requireSafeDirectory(LocalTunWire.installationDirectory)
        try requireRootFile(LocalTunWire.workerPath)
    }

    static func requireSafeDirectory(_ path: String) throws {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        var current = URL(fileURLWithPath: resolved, isDirectory: true)
        while true {
            var metadata = stat()
            guard lstat(current.path, &metadata) == 0,
                  metadata.st_mode & S_IFMT == S_IFDIR,
                  metadata.st_uid == 0, metadata.st_mode & 0o022 == 0 else {
                throw HelperFailure("特权服务目录的所有权或权限不安全。")
            }
            if current.path == "/" { break }
            current.deleteLastPathComponent()
        }
    }

    static func requireRootFile(_ path: String) throws {
        var metadata = stat()
        guard lstat(path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == 0, metadata.st_mode & 0o022 == 0 else {
            throw HelperFailure("特权服务文件的所有权或权限不安全。")
        }
    }
}

/// Reports a privileged-helper failure without exposing caller-supplied configuration.
struct HelperFailure: LocalizedError {
    let message: String
    let failure: LocalTunFailure?
    init(_ message: String, failure: LocalTunFailure? = nil) { self.message = message; self.failure = failure }
    static func safeFailure(_ error: Error) -> LocalTunFailure {
        if error is CancellationError { return LocalTunFailure(.cancelled) }
        if error is LocalTunProtocolError { return LocalTunFailure(.invalidRequest) }
        guard let helper = error as? HelperFailure else { return LocalTunFailure(.unknown) }
        if let failure = helper.failure { return failure }
        switch helper.message {
        case "无法更新或恢复系统 DNS 设置。", "DNS 恢复记录大小无效。", "存在待恢复的 DNS 设置，请先恢复。":
            return LocalTunFailure(.dnsFailed)
        case "特权服务目录的所有权或权限不安全。", "特权服务文件的所有权或权限不安全。":
            return LocalTunFailure(.permissions)
        default: return LocalTunFailure(.unknown)
        }
    }
    var errorDescription: String? { message }
}

/// Shares termination requests between dispatch signal handlers and bounded blocking loops.
final class HelperTermination: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false
    private var sources: [DispatchSourceSignal] = []
    var isRequested: Bool { lock.lock(); defer { lock.unlock() }; return requested }

    func monitor() {
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .utility))
            source.setEventHandler { [weak self] in self?.request() }
            source.resume()
            sources.append(source)
        }
    }

    private func request() { lock.lock(); requested = true; lock.unlock() }
}

/// Writes structured failure metadata to the daemon log without emitting raw errors or configuration.
enum HelperDiagnostics {
    static func record(_ failure: LocalTunFailure) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var data = try? encoder.encode(LocalTunDiagnosticRecord(failure: failure)) else { return }
        data.append(10)
        try? FileHandle.standardError.write(contentsOf: data)
    }
}
