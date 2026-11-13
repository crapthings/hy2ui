import Foundation
import Darwin

/// Supervises the installed official TUN CLI and tracks readiness without forwarding raw logs.
final class PrivilegedWorker {
    /// Uses clap-compatible boolean text while keeping the privileged environment bounded.
    static let launchEnvironment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/var/root", "HYSTERIA_DISABLE_UPDATE_CHECK": "true"]
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var diagnostics = CoreDiagnosticParser()
    private var outputClosed = false
    private(set) var interfaceSession: LocalTunInterfaceSession?
    var isRunning: Bool { process.isRunning }

    func start(configuration: LocalTunConfiguration, connection: HelperSocket, termination: HelperTermination) throws {
        try TrustedInstallation.validate()
        try configuration.validate()
        let features = try PrivilegedCoreCommand.timed("探测核心能力", connection: connection) { try PrivilegedCoreCommand.features() }
        let journal = features.journal ? LocalTunWire.routeJournalPath : nil
        let sessionID = features.sessions ? UUID() : nil
        let data = try PrivilegedCoreCommand.timed("生成 TUN 配置", connection: connection) {
            try CLITunConfiguration.make(configuration, routeJournalPath: journal, sessionID: sessionID, parentPID: UInt32(getpid()))
        }
        lock.lock()
        diagnostics = CoreDiagnosticParser()
        lock.unlock()
        process.executableURL = URL(fileURLWithPath: LocalTunWire.workerPath)
        process.arguments = ["client", "--config", "/dev/stdin", "--disable-update-check"]
        process.environment = Self.launchEnvironment
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = output
        let readDescriptor = output.fileHandleForReading.fileDescriptor
        let readFlags = fcntl(readDescriptor, F_GETFL)
        guard readFlags >= 0, fcntl(readDescriptor, F_SETFL, readFlags | O_NONBLOCK) != -1 else {
            throw HelperFailure("无法配置客户端日志管道。")
        }
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in self?.readOutput(handle) }
        do {
            let coreStart = DispatchTime.now().uptimeNanoseconds
            var reportedServer = false, reportedInterface = false
            do { try process.run() }
            catch { throw HelperFailure("TUN 客户端启动失败。", failure: LocalTunFailure(.startupFailed)) }
            try input.fileHandleForReading.close()
            try output.fileHandleForWriting.close()
            try writeConfiguration(data, connection: connection, termination: termination)
            try input.fileHandleForWriting.close()
            let deadline = ContinuousClock.now + .seconds(30)
            while true {
                try checkCancellation(connection, termination: termination)
                guard process.isRunning else { throw HelperFailure("TUN 客户端启动失败。", failure: exitFailure(.startupFailed)) }
                lock.lock()
                let ready = diagnostics.ready
                let authenticated = diagnostics.serverAuthenticated
                let interfaceReady = diagnostics.nativeInterfaceReady
                lock.unlock()
                if authenticated && !reportedServer {
                    reportedServer = true
                    PrivilegedCoreCommand.recordTime("核心已认证服务器（自进程启动）", since: coreStart, connection: connection)
                }
                if interfaceReady && !reportedInterface {
                    reportedInterface = true
                    PrivilegedCoreCommand.recordTime("核心已建立网卡及路由（自进程启动）", since: coreStart, connection: connection)
                }
                if ready { break }
                guard ContinuousClock.now < deadline else { throw HelperFailure("TUN 客户端连接超时。", failure: LocalTunFailure(.startupTimedOut)) }
                Thread.sleep(forTimeInterval: 0.02)
            }
            guard process.isRunning else { throw HelperFailure("TUN 客户端启动后退出。", failure: exitFailure(.startupFailed)) }
            if let sessionID {
                interfaceSession = try PrivilegedCoreCommand.timed("验证接口会话身份", connection: connection) {
                    try PrivilegedCoreCommand.activeSession(id: sessionID, workerPID: process.processIdentifier)
                }
            }
            guard process.isRunning else { throw HelperFailure("TUN 客户端启动后退出。", failure: exitFailure(.startupFailed)) }
        } catch {
            try? stop()
            lock.lock(); let knownFailure = diagnostics.startupFailure; lock.unlock()
            if let knownFailure { throw HelperFailure(knownFailure.message, failure: exitFailure(knownFailure)) }
            throw error
        }
    }

    func exitFailure(_ code: LocalTunFailureCode = .workerExited) -> LocalTunFailure {
        lock.lock(); let coreFailure = diagnostics.coreFailure; let coreReason = diagnostics.coreReason; lock.unlock()
        guard process.processIdentifier > 0, !process.isRunning else { return LocalTunFailure(code, coreFailure: coreFailure, coreReason: coreReason) }
        return LocalTunFailure(code, exitStatus: process.terminationStatus,
                               terminatedBySignal: process.terminationReason == .uncaughtSignal, coreFailure: coreFailure, coreReason: coreReason)
    }

    func takeDiagnosticEvents() -> [LocalTunEvent] {
        lock.lock(); defer { lock.unlock() }
        return diagnostics.drain().map { LocalTunEvent(kind: .log, message: $0.message, coreEvent: $0) }
            + diagnostics.drainFlowDiagnostics().map { LocalTunEvent(kind: .log, message: $0.logMessage) }
            + diagnostics.drainTelemetry().map { LocalTunEvent(kind: .log, metrics: $0) }
    }

    func stop() throws {
        if process.isRunning {
            process.interrupt()
            waitForExit(seconds: 6)
            if process.isRunning { process.terminate(); waitForExit(seconds: 1) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL); waitForExit(seconds: 1) }
        }
        guard !process.isRunning else { throw HelperFailure("TUN 客户端尚未退出，请重试恢复。") }
        lock.lock()
        // Capture the final metric frame emitted during graceful core shutdown before closing the pipe.
        if !outputClosed {
            // Preflight may have failed before start configured this pipe.
            let descriptor = output.fileHandleForReading.fileDescriptor
            let flags = fcntl(descriptor, F_GETFL)
            if flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 {
                var remaining = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = read(descriptor, &remaining, remaining.count)
                    guard count > 0 else { break }
                    diagnostics.consume(Data(remaining.prefix(count)))
                }
            }
        }
        outputClosed = true
        output.fileHandleForReading.readabilityHandler = nil
        try? output.fileHandleForReading.close()
        lock.unlock()
        for handle in [input.fileHandleForReading, input.fileHandleForWriting,
                       output.fileHandleForWriting] { try? handle.close() }
        if process.processIdentifier > 0 { try Self.recoverDirectRoutes() }
        interfaceSession = nil
    }

    /// Recovers the new core journal while preserving legacy records for their original worker.
    static func recoverDirectRoutes() throws {
        if FileManager.default.fileExists(atPath: LocalTunWire.directRoutesJournalPath) {
            throw HelperFailure("发现旧版分流路由记录，请先使用旧版后台完成清理，再更新后台。", failure: LocalTunFailure(.recoveryFailed))
        }
        try PrivilegedCoreCommand.recoverRouteJournal()
    }

    private func writeConfiguration(_ data: Data, connection: HelperSocket, termination: HelperTermination) throws {
        guard data.count <= LocalTunWire.maxMessageBytes else { throw LocalTunProtocolError.messageTooLarge }
        let descriptor = input.fileHandleForWriting.fileDescriptor
        guard fcntl(descriptor, F_SETNOSIGPIPE, 1) != -1 else { throw HelperFailure("无法建立安全配置管道。") }
        let flags = fcntl(descriptor, F_GETFL)
        guard flags != -1, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1 else { throw HelperFailure("无法配置输入管道。") }
        let deadline = ContinuousClock.now + .seconds(5)
        var offset = 0
        while offset < data.count {
            try checkCancellation(connection, termination: termination)
            let count = data.withUnsafeBytes { bytes in
                write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if count > 0 { offset += count; continue }
            guard count < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR,
                  process.isRunning, ContinuousClock.now < deadline else { throw HelperFailure("无法发送 TUN 配置。") }
            var events = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            _ = poll(&events, 1, 50)
        }
    }

    private func checkCancellation(_ connection: HelperSocket, termination: HelperTermination) throws {
        guard !termination.isRequested, !connection.hasPendingInputOrClosed() else { throw CancellationError() }
    }

    private func readOutput(_ handle: FileHandle) {
        lock.lock()
        guard !outputClosed else { lock.unlock(); return }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = read(handle.fileDescriptor, &buffer, buffer.count)
        if count == 0 { handle.readabilityHandler = nil }
        lock.unlock()
        if count > 0 { consume(Data(buffer.prefix(count))) }
    }

    private func consume(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        diagnostics.consume(data)
    }

    private func waitForExit(seconds: Int) {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while process.isRunning && ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.02) }
    }
}
