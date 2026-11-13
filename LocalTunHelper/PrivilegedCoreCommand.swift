import Foundation
import Darwin

/// Runs bounded, credential-free commands against the trusted installed core.
enum PrivilegedCoreCommand {
    static func run(_ arguments: [String], binary: URL = URL(fileURLWithPath: LocalTunWire.workerPath),
                    timeout: Duration = .seconds(5), validate: () throws -> Void = { try TrustedInstallation.validate() }) throws -> [String: Any] {
        try validate()
        let process = Process(), output = Pipe()
        process.executableURL = binary; process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/var/root"]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        let reader = output.fileHandleForReading
        let descriptor = reader.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else { throw failure() }
        defer { try? reader.close(); try? output.fileHandleForWriting.close() }
        try process.run()
        try output.fileHandleForWriting.close()
        let deadline = ContinuousClock.now + timeout
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        do {
            while true {
                let count = read(descriptor, &buffer, buffer.count)
                if count > 0 {
                    bytes.append(contentsOf: buffer.prefix(count))
                    guard bytes.count <= 65_536 else { throw failure() }
                } else if count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { throw failure() }
                if !process.isRunning && count <= 0 { break }
                guard ContinuousClock.now < deadline else { throw failure() }
                if count <= 0 { Thread.sleep(forTimeInterval: 0.01) }
            }
            guard process.terminationReason == .exit, process.terminationStatus == 0,
                  let result = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  result["schema_version"] as? Int == 1 else { throw failure() }
            return result
        } catch {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                let killDeadline = ContinuousClock.now + .seconds(1)
                while process.isRunning && ContinuousClock.now < killDeadline { Thread.sleep(forTimeInterval: 0.01) }
            }
            throw failure()
        }
    }

    static func features() throws -> (journal: Bool, sessions: Bool) {
        let report = try run(["capabilities", "--output", "json"])
        guard let tun = report["tun"] as? [String: Any] else { throw failure() }
        let journal = tun["route_journal"] as? Bool == true && tun["route_recovery"] as? Bool == true
        return (journal, journal && tun["session_tracking"] as? Bool == true && tun["parent_loss_shutdown"] as? Bool == true)
    }

    static func recordedSession(timeout: Duration = .seconds(5)) throws -> LocalTunInterfaceSession? {
        var metadata = stat()
        guard lstat(LocalTunWire.routeJournalPath, &metadata) == 0 else {
            guard errno == ENOENT else { throw failure() }; return nil
        }
        try TrustedInstallation.requireRootFile(LocalTunWire.routeJournalPath)
        let report = try run(["recover-tun-routes", "--journal", LocalTunWire.routeJournalPath], timeout: timeout)
        return try decodeSession(report["session"])
    }

    static func activeSession(id: UUID, workerPID: Int32) throws -> LocalTunInterfaceSession {
        guard workerPID > 1, let session = try recordedSession() else { throw failure() }
        guard UUID(uuidString: session.id) == id, session.process.pid == UInt32(workerPID),
              session.process.isCurrent, session.interface.isCurrent,
              session.parent?.pid == UInt32(getpid()), session.parent?.isCurrent == true else { throw failure() }
        return session
    }

    /// Confirms idle ownership without applying recovery or launching another core process.
    static func checkIdleRouteJournal(path: String = LocalTunWire.routeJournalPath,
                                      validateJournal: (String) throws -> Void = { try TrustedInstallation.requireRootFile($0) }) throws {
        var metadata = stat()
        if lstat(path, &metadata) == 0 { throw failure() }
        guard errno == ENOENT else { throw failure() }
        try verifyIdleLease(path: path, validate: validateJournal)
    }

    /// Emits only fixed stage labels and monotonic elapsed time; diagnostics never replace an operation error.
    static func timed<T>(_ title: String, connection: HelperSocket, operation: () throws -> T) throws -> T {
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            let result = try operation()
            recordTime(title, since: start, connection: connection)
            return result
        } catch {
            recordTime(title + "（失败）", since: start, connection: connection)
            throw error
        }
    }

    static func recordTime(_ title: String, since start: UInt64, connection: HelperSocket) {
        let milliseconds = (DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        try? connection.send(LocalTunEvent(kind: .log, message: "启动阶段：\(title)，耗时 \(milliseconds) ms"))
    }

    static func recoverRouteJournal(path: String = LocalTunWire.routeJournalPath,
                                    binary: URL = URL(fileURLWithPath: LocalTunWire.workerPath),
                                    validateInstallation: () throws -> Void = { try TrustedInstallation.validate() },
                                    validateJournal: (String) throws -> Void = { try TrustedInstallation.requireRootFile($0) }) throws {
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else {
            guard errno == ENOENT else { throw failure() }
            try verifyIdleLease(path: path, validate: validateJournal)
            return
        }
        try validateJournal(path)
        let inspection = try run(["recover-tun-routes", "--journal", path], binary: binary, validate: validateInstallation)
        _ = try decodeSession(inspection["session"])
        let report = try run(["recover-tun-routes", "--journal", path, "--apply"], binary: binary, timeout: .seconds(10), validate: validateInstallation)
        guard report["recovered"] as? Bool == true, report["journal_present"] as? Bool == false else { throw failure() }
        guard lstat(path, &metadata) != 0, errno == ENOENT else { throw failure() }
    }

    private static func decodeSession(_ object: Any?) throws -> LocalTunInterfaceSession? {
        guard let object, !(object is NSNull) else { return nil }
        guard let value = object as? [String: Any] else { throw failure() }
        do {
            let session = try JSONDecoder().decode(LocalTunInterfaceSession.self, from: JSONSerialization.data(withJSONObject: value))
            try session.validate()
            return session
        } catch { throw failure() }
    }

    private static func verifyIdleLease(path: String, validate: (String) throws -> Void) throws {
        let lockPath = path + ".lock"
        let descriptor = open(lockPath, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            guard errno == ENOENT else { throw failure() }
            return
        }
        defer { close(descriptor) }
        try validate(lockPath)
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(), metadata.st_nlink == 1, metadata.st_mode & 0o077 == 0,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw failure() }
        defer { flock(descriptor, LOCK_UN) }
        guard lstat(path, &metadata) != 0, errno == ENOENT else { throw failure() }
    }

    private static func failure() -> HelperFailure {
        HelperFailure("核心检查或路由恢复未确认，已保留恢复记录。", failure: LocalTunFailure(.recoveryFailed))
    }
}
