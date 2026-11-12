import Foundation
import Darwin

/// Owns one official CLI process and keeps credentials in an inherited pipe throughout its lifetime.
@MainActor
final class CoreWorkerSession {
    enum Phase { case starting, running, stopping, exited }
    let id = UUID()
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    var phase = Phase.starting
    var tail = ""
    var readiness = Set<String>()
    var requiredReadiness: Set<String> = ["connection", "socks", "http"]
    var inputTask: Task<Void, Error>?

    func closePipes() {
        output.fileHandleForReading.readabilityHandler = nil
        for handle in [input.fileHandleForWriting, input.fileHandleForReading,
                       output.fileHandleForReading, output.fileHandleForWriting] {
            try? handle.close()
        }
    }
}

/// Starts and stops a single Rust proxy worker while coordinating readiness with process termination.
@MainActor
final class CoreProcess {
    private var session: CoreWorkerSession?
    private var stopTask: Task<Void, Never>?
    private let binaryURL: URL
    var onTelemetry: ((CoreTelemetryObservation) -> Void)?
    var onExit: (() -> Void)?
    var onLog: ((String) -> Void)?
    var isRunning: Bool { session?.process.isRunning == true }

    init(binaryURL: URL? = nil) {
        self.binaryURL = binaryURL ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/hysteria")
    }

    func start(configuration: Data, credentials: Credentials) async throws {
        try Task.checkCancellation()
        guard session == nil, stopTask == nil else { throw ConfigurationError.invalid("客户端已在运行或正在停止。") }
        guard !configuration.isEmpty, configuration.count <= 1_048_576 else {
            throw ConfigurationError.invalid("客户端配置大小无效。")
        }
        let binary = binaryURL
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw ConfigurationError.invalid("应用未包含官方 CLI，请先运行 Scripts/prepare-cli.py。")
        }
        let current = CoreWorkerSession()
        if try DesktopCoreConfiguration.object(configuration)["lazy"] as? Bool == true {
            current.requiredReadiness.remove("connection")
        }
        configure(current, binary: binary, credentials: credentials)
        session = current
        do {
            try current.process.run()
            // Prevent SIGPIPE from terminating the UI if the worker closes stdin early.
            guard fcntl(current.input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
                throw ConfigurationError.invalid("无法安全创建客户端配置管道。")
            }
            try current.input.fileHandleForReading.close()
            try current.output.fileHandleForWriting.close()
            let writer = current.input.fileHandleForWriting
            current.inputTask = Task.detached(priority: .userInitiated) {
                defer { try? writer.close() }
                try writer.write(contentsOf: configuration)
            }
            try await waitUntilReady(current)
            try await current.inputTask?.value
            try Task.checkCancellation()
            guard session === current, current.phase == .starting, current.process.isRunning else {
                throw ConfigurationError.invalid("Rust 客户端在启动过程中退出。")
            }
            current.phase = .running
        } catch {
            await stop()
            throw error
        }
    }

    private func configure(_ current: CoreWorkerSession, binary: URL, credentials: Credentials) {
        current.process.environment = ProcessInfo.processInfo.environment
        current.process.executableURL = binary
        current.process.arguments = ["client", "--config", "/dev/stdin", "--disable-update-check"]
        current.process.standardInput = current.input
        current.process.standardOutput = FileHandle.nullDevice
        current.process.standardError = current.output
        let token = current.id
        current.output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self?.consume(text, credentials: credentials, token: token) }
        }
        current.process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.workerDidExit(token: token) }
        }
    }

    private func waitUntilReady(_ current: CoreWorkerSession) async throws {
        let deadline = ContinuousClock.now + .seconds(25)
        while true {
            try Task.checkCancellation()
            guard session === current, current.phase == .starting, current.process.isRunning else {
                throw ConfigurationError.invalid("Rust 客户端启动失败，请查看日志。")
            }
            if current.requiredReadiness.isSubset(of: current.readiness) { return }
            guard ContinuousClock.now < deadline else { throw ConfigurationError.invalid("连接服务器超时。") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func workerDidExit(token: UUID) {
        guard let current = session, current.id == token, current.phase != .stopping, current.phase != .exited else { return }
        current.phase = .exited
        onExit?()
    }

    private func consume(_ text: String, credentials: Credentials, token: UUID) {
        guard let current = session, current.id == token else { return }
        current.tail += text
        while let newline = current.tail.firstIndex(of: "\n") {
            var line = String(current.tail[..<newline])
            current.tail.removeSubrange(...newline)
            if let sample = CoreTelemetry.parse(line) {
                onTelemetry?(CoreTelemetryObservation(session: current.id, metrics: sample))
                continue
            }
            if current.phase == .stopping { continue }
            if line.hasPrefix("connected to ") { current.readiness.insert("connection") }
            if line.hasPrefix("SOCKS5 proxy listening on ") { current.readiness.insert("socks") }
            if line.hasPrefix("HTTP proxy listening on ") { current.readiness.insert("http") }
            for secret in [credentials.password, credentials.obfuscationPassword] where !secret.isEmpty {
                line = line.replacingOccurrences(of: secret, with: "••••")
            }
            onLog?(String(line.prefix(2000)))
        }
        if current.tail.count > 8192 { current.tail = String(current.tail.suffix(8192)) }
    }

    func stop() async {
        if let stopTask { await stopTask.value; return }
        guard let current = session else { return }
        current.phase = .stopping
        current.process.terminationHandler = nil
        let task = Task { @MainActor in
            await self.terminate(current.process)
            try? await current.inputTask?.value
            current.closePipes()
            if self.session === current { self.session = nil }
        }
        stopTask = task
        await task.value
        stopTask = nil
    }

    private func terminate(_ process: Process) async {
        guard process.isRunning else { return }
        process.interrupt()
        await waitForExit(process, seconds: 3)
        if process.isRunning { process.terminate() }
        await waitForExit(process, seconds: 1)
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        await waitForExit(process, seconds: 1)
    }

    private func waitForExit(_ process: Process, seconds: Int) async {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while process.isRunning && ContinuousClock.now < deadline {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { continuation.resume() }
            }
        }
    }
}
