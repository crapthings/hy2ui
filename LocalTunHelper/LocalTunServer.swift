import Foundation
import Darwin

/// Serves one authenticated TUN session at a time and retains failed cleanup ownership for retry.
final class LocalTunServer {
    private let allowedUID: uid_t
    private let termination: HelperTermination
    private let dns = PrivilegedDNS()
    private var worker: PrivilegedWorker?
    private var listener: Int32 = -1

    init(allowedUID: uid_t, termination: HelperTermination) {
        self.allowedUID = allowedUID
        self.termination = termination
    }

    func run() throws {
        try TrustedInstallation.validate()
        // Attempt startup recovery, but keep IPC reachable if records need attention.
        do { try cleanup() }
        catch { HelperDiagnostics.record(LocalTunFailure(.recoveryFailed)) }
        try createListener()
        defer { if listener >= 0 { close(listener) }; unlink(LocalTunWire.socketPath) }
        while !termination.isRequested {
            var event = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            let result = poll(&event, 1, 100)
            if result < 0 && errno != EINTR { throw HelperFailure("本地增强模式监听失败。") }
            guard result > 0 else { continue }
            let descriptor = accept(listener, nil, nil)
            guard descriptor >= 0 else { if errno == EINTR || errno == EAGAIN { continue }; throw HelperFailure("无法接受本地连接。") }
            let connection = HelperSocket(descriptor: descriptor)
            do {
                try connection.authenticate(allowedUID: allowedUID)
                try serve(connection)
            } catch {
                let failure = HelperFailure.safeFailure(error)
                HelperDiagnostics.record(failure)
                let identity = worker?.interfaceSession ?? (try? PrivilegedCoreCommand.recordedSession(timeout: .seconds(1)))
                try? connection.send(LocalTunEvent(kind: .error, message: failure.code.message, failure: failure, interfaceSession: identity))
            }
            connection.closeSocket()
        }
        try cleanup()
    }

    private func serve(_ connection: HelperSocket) throws {
        guard let request = try connection.readRequest(timeout: .seconds(5), termination: termination) else {
            throw HelperFailure("本地增强模式请求超时。")
        }
        // A query must not enter the mutating failure-cleanup path either.
        if request.command == .status {
            guard worker == nil, !dns.needsRecovery,
                  !FileManager.default.fileExists(atPath: LocalTunWire.directRoutesJournalPath) else {
                throw HelperFailure("存在待恢复会话。", failure: LocalTunFailure(.recoveryFailed))
            }
            try PrivilegedCoreCommand.checkIdleRouteJournal()
            try connection.send(LocalTunEvent(kind: .stopped))
            return
        }
        do { try handle(request, connection: connection) }
        catch {
            let original = error
            do { try cleanup() }
            catch { throw HelperFailure("后台网络恢复失败，请重试清理。", failure: LocalTunFailure(.recoveryFailed)) }
            throw original
        }
    }

    private func handle(_ request: LocalTunRequest, connection: HelperSocket) throws {
        switch request.command {
        case .status:
            throw LocalTunProtocolError.invalidMessage
        case .stop:
            try cleanup()
            try connection.send(LocalTunEvent(kind: .stopped))
            return
        case .start:
            let totalStart = DispatchTime.now().uptimeNanoseconds
            try PrivilegedCoreCommand.timed("检查与恢复旧会话", connection: connection) { try cleanup() }
            guard let configuration = request.configuration else { throw LocalTunProtocolError.invalidConfiguration }
            let current = PrivilegedWorker()
            worker = current
            try current.start(configuration: configuration, connection: connection, termination: termination)
            if configuration.finalDirect != true {
                try PrivilegedCoreCommand.timed("应用系统 DNS", connection: connection) {
                    try dns.enable(servers: configuration.dns, bypassLocalNetworks: configuration.bypassLocalNetworks ?? true)
                }
            }
            guard current.isRunning else {
                throw HelperFailure("TUN 客户端已退出。", failure: current.exitFailure())
            }
            PrivilegedCoreCommand.recordTime("增强模式启动总计", since: totalStart, connection: connection)
            try connection.send(LocalTunEvent(kind: .ready, interfaceSession: current.interfaceSession))
        }

        while !termination.isRequested {
            guard worker?.isRunning == true else {
                throw HelperFailure("TUN 客户端已退出。", failure: worker?.exitFailure() ?? LocalTunFailure(.workerExited))
            }
            for event in worker?.takeDiagnosticEvents() ?? [] { try connection.send(event) }
            guard let request = try connection.readRequest(timeout: nil, termination: termination) else { continue }
            guard request.command == .stop else { throw LocalTunProtocolError.invalidMessage }
            let completed = worker
            try cleanup()
            for event in completed?.takeDiagnosticEvents() ?? [] { try connection.send(event) }
            try connection.send(LocalTunEvent(kind: .stopped))
            return
        }
        throw CancellationError()
    }

    private func cleanup() throws {
        // DNS is restored before closing the tunnel so resolver traffic is never left pointing into a dead session.
        try dns.restore()
        if let worker {
            try worker.stop()
            self.worker = nil
        } else {
            try PrivilegedWorker.recoverDirectRoutes()
        }
    }

    private func createListener() throws {
        try TrustedInstallation.requireSafeDirectory(LocalTunWire.installationDirectory)
        var existing = stat()
        if lstat(LocalTunWire.socketPath, &existing) == 0 {
            guard existing.st_mode & S_IFMT == S_IFSOCK,
                  existing.st_uid == allowedUID || existing.st_uid == 0 else { throw HelperFailure("本地服务套接字路径不安全。") }
            guard unlink(LocalTunWire.socketPath) == 0 else { throw HelperFailure("无法移除旧的服务套接字。") }
        } else if errno != ENOENT { throw HelperFailure("无法检查服务套接字。") }
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw HelperFailure("无法建立本地服务套接字。") }
        let flags = fcntl(listener, F_GETFL)
        guard flags >= 0, fcntl(listener, F_SETFL, flags | O_NONBLOCK) != -1 else { throw HelperFailure("无法配置本地服务套接字。") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let path = Array(LocalTunWire.socketPath.utf8CString)
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw HelperFailure("本地服务路径过长。") }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in buffer.copyBytes(from: path.map { UInt8(bitPattern: $0) }) }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chown(LocalTunWire.socketPath, allowedUID, 0) == 0,
              chmod(LocalTunWire.socketPath, 0o600) == 0, listen(listener, 4) == 0 else {
            throw HelperFailure("无法安装本地服务套接字。")
        }
    }
}
