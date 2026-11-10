import Foundation

/// Exercises the worker lifecycle with local mock processes that never open network listeners.
@main
struct CoreProcessSmoke {
    @MainActor
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hy2ui-process-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = try JSONSerialization.data(withJSONObject: ["auth": "test-secret\nquoted\"value"])
        let runningWorker = try writeWorker(at: directory.appendingPathComponent("running-worker"), body: """
        import json, sys, time
        assert sys.argv[1:] == ['--config-stdin']
        assert json.load(sys.stdin)['auth'] == 'test-secret\\nquoted"value'
        for line in ['connected to test', 'SOCKS5 proxy listening on test', 'HTTP proxy listening on test']:
            print(line, file=sys.stderr, flush=True)
        time.sleep(30)
        """)
        let core = CoreProcess(binaryURL: runningWorker)
        try await core.start(configuration: configuration, credentials: Credentials(password: "test-secret\nquoted\"value"))
        precondition(core.isRunning, "stdin delivery must precede readiness")
        async let firstStop: Void = core.stop()
        async let secondStop: Void = core.stop()
        _ = await (firstStop, secondStop)
        precondition(!core.isRunning, "concurrent stops must complete after worker exit")

        let exitingWorker = try writeWorker(at: directory.appendingPathComponent("exiting-worker"), body: """
        import os, sys
        sys.stdin.read()
        sys.stderr.write('connected to test\\n')
        sys.stderr.flush()
        os._exit(0)
        """)
        let failingCore = CoreProcess(binaryURL: exitingWorker)
        do {
            try await failingCore.start(configuration: configuration, credentials: Credentials())
            preconditionFailure("an early-exit worker must not complete startup")
        } catch {
            precondition(!failingCore.isRunning)
        }
        print("CoreProcess stdin delivery, early-exit rejection and concurrent-stop smoke checks passed.")
    }

    private static func writeWorker(at url: URL, body: String) throws -> URL {
        try Data(("#!/usr/bin/env python3\n" + body + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}
