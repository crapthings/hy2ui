import Foundation
import Darwin

/// Exercises bounded helper commands with fake ordinary-user executables and no network changes.
@main struct PrivilegedCoreSmoke {
    static func main() throws {
        if let binary = ProcessInfo.processInfo.environment["HY2_TEST_CLI"] {
            let process = Process(), input = Pipe(), errors = Pipe()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = ["client", "--config", "/dev/stdin", "--disable-update-check"]
            process.environment = PrivilegedWorker.launchEnvironment
            process.standardInput = input; process.standardOutput = FileHandle.nullDevice; process.standardError = errors
            try process.run()
            try input.fileHandleForReading.close(); try errors.fileHandleForWriting.close()
            // Invalid dummy config must fail before networking; exit 2 would indicate argument parsing failure.
            try input.fileHandleForWriting.write(contentsOf: Data("{}".utf8)); try input.fileHandleForWriting.close()
            let deadline = ContinuousClock.now + .seconds(5)
            while process.isRunning && ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL); preconditionFailure("CLI validation did not exit") }
            let diagnostic = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            try errors.fileHandleForReading.close()
            precondition(process.terminationStatus == 1 && diagnostic.contains("[configuration_parse]"), "helper environment must reach config validation, not fail CLI argument parsing")
        }
        let neverStarted = PrivilegedWorker()
        let stopStart = ContinuousClock.now
        try neverStarted.stop(); try neverStarted.stop()
        precondition(ContinuousClock.now - stopStart < .seconds(1), "preflight rollback must not block on an unused pipe")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func worker(_ name: String, _ body: String) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try Data(("#!/usr/bin/python3\n" + body + "\n").utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return url
        }
        let success = try worker("success", "print('{\"schema_version\":1,\"recovered\":true,\"journal_present\":false}')")
        let result = try PrivilegedCoreCommand.run([], binary: success, validate: {})
        precondition(result["recovered"] as? Bool == true)
        for (name, body) in [("failure", "import sys; print('{\"schema_version\":1}'); sys.exit(1)"),
                             ("invalid", "print('not json')"), ("overflow", "print('x' * 70000)"),
                             ("timeout", "import time; time.sleep(20)")] {
            let binary = try worker(name, body)
            do {
                _ = try PrivilegedCoreCommand.run([], binary: binary, timeout: .milliseconds(300), validate: {})
                preconditionFailure("unsafe core result accepted: \(name)")
            } catch {
                precondition(HelperFailure.safeFailure(error).code == .recoveryFailed)
            }
        }
        let journal = directory.appendingPathComponent("journal.json")
        try PrivilegedCoreCommand.checkIdleRouteJournal(path: journal.path, validateJournal: { _ in preconditionFailure("missing lease must not be validated") })
        precondition(!FileManager.default.fileExists(atPath: journal.path + ".lock"))
        try Data("receipt".utf8).write(to: journal)
        do {
            try PrivilegedCoreCommand.checkIdleRouteJournal(path: journal.path, validateJournal: { _ in })
            preconditionFailure("a pending journal was reported idle")
        } catch {
            let preserved = try Data(contentsOf: journal)
            precondition(preserved == Data("receipt".utf8))
        }
        do {
            try PrivilegedCoreCommand.recoverRouteJournal(path: journal.path, binary: success, validateInstallation: {}, validateJournal: { _ in })
            preconditionFailure("a success reply with an unrecovered journal was accepted")
        } catch { precondition(FileManager.default.fileExists(atPath: journal.path)) }
        let foreign = try worker("foreign-owner", """
        import json, os, sys
        if '--apply' in sys.argv: os.unlink(sys.argv[3])
        print(json.dumps({'schema_version':1,'journal_present':True,'session':{'id':'00000000-0000-4000-8000-000000000001','owner':'another.app','process':{'pid':1234,'start_seconds':100,'start_microseconds':1},'interface':{'name':'utun321','index':42}}}))
        """)
        do {
            try PrivilegedCoreCommand.recoverRouteJournal(path: journal.path, binary: foreign, validateInstallation: {}, validateJournal: { _ in })
            preconditionFailure("a foreign owner's interface record was applied")
        } catch { precondition(FileManager.default.fileExists(atPath: journal.path)) }
        let recovery = try worker("recovery", "import os, sys; \nif '--apply' in sys.argv: os.unlink(sys.argv[3])\nprint('{\"schema_version\":1,\"recovered\":true,\"journal_present\":false}')")
        try PrivilegedCoreCommand.recoverRouteJournal(path: journal.path, binary: recovery, validateInstallation: {}, validateJournal: { _ in })
        precondition(!FileManager.default.fileExists(atPath: journal.path))
        // Missing journals must not execute a command or require any privileged validation.
        try PrivilegedCoreCommand.recoverRouteJournal(path: journal.path, binary: directory.appendingPathComponent("missing"), validateInstallation: { preconditionFailure("unexpected command") }, validateJournal: { _ in preconditionFailure("unexpected validation") })
        let lease = journal.path + ".lock"
        let descriptor = open(lease, O_CREAT | O_RDWR, 0o600)
        precondition(descriptor >= 0 && flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        do {
            try PrivilegedCoreCommand.checkIdleRouteJournal(path: journal.path, validateJournal: { _ in })
            preconditionFailure("read-only query accepted a held lease")
        } catch { precondition(HelperFailure.safeFailure(error).code == .recoveryFailed) }
        do {
            try PrivilegedCoreCommand.recoverRouteJournal(path: journal.path, binary: success, validateInstallation: {}, validateJournal: { _ in })
            preconditionFailure("an active writer with no journal yet was accepted as stopped")
        } catch { precondition(HelperFailure.safeFailure(error).code == .recoveryFailed) }
        flock(descriptor, LOCK_UN); close(descriptor)
        try PrivilegedCoreCommand.checkIdleRouteJournal(path: journal.path, validateJournal: { _ in })
        try PrivilegedCoreCommand.recoverRouteJournal(path: journal.path, binary: directory.appendingPathComponent("missing"), validateInstallation: { preconditionFailure("idle lease must not launch a core") }, validateJournal: { _ in })
        print("Helper core commands reject failed, malformed, excessive and timed-out replies.")
    }
}
