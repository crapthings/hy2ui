import Foundation
import Network

/// Serves one immutable PAC script on an unpredictable loopback URL for the active connection.
@MainActor
final class PACServer {
    private var listener: NWListener?
    private var generation = UUID()
    private var startup: CheckedContinuation<URL, Error>?
    private let queue = DispatchQueue(label: "dev.hy2ui.pac")
    private var clients: [UUID: PACRequest] = [:]

    func start(script: String) async throws -> URL {
        stop()
        let token = UUID(); generation = token
        let path = "/\(token.uuidString)/proxy.pac"
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let server = try NWListener(using: parameters)
        listener = server
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                startup = continuation
                server.stateUpdateHandler = { [weak self] state in
                    Task { @MainActor in
                        guard let self, self.generation == token else { return }
                        switch state {
                        case .ready:
                            guard let port = self.listener?.port, let url = URL(string: "http://127.0.0.1:\(port.rawValue)\(path)") else {
                                self.fail(); return
                            }
                            let pending = self.startup; self.startup = nil
                            pending?.resume(returning: url)
                        case .failed, .cancelled: self.fail()
                        default: break
                        }
                    }
                }
                server.newConnectionHandler = { [weak self] connection in
                    Task { @MainActor in
                        guard let self, self.generation == token, self.clients.count < 16 else { connection.cancel(); return }
                        let id = UUID()
                        let request = PACRequest(connection: connection, path: path, script: script, queue: self.queue) { [weak self] in
                            Task { @MainActor in self?.clients.removeValue(forKey: id) }
                        }
                        self.clients[id] = request
                        request.start()
                    }
                }
                server.start(queue: queue)
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    guard let self, self.generation == token, self.startup != nil else { return }
                    self.fail()
                }
                if Task.isCancelled { stop() }
            }
        } onCancel: { Task { @MainActor [weak self] in if self?.generation == token { self?.stop() } } }
    }

    func stop() {
        generation = UUID()
        listener?.cancel(); listener = nil
        let pending = startup; startup = nil
        pending?.resume(throwing: CancellationError())
        for client in clients.values { client.cancel() }
        clients.removeAll()
    }

    private func fail() {
        let pending = startup; startup = nil
        pending?.resume(throwing: ConfigurationError.invalid("无法启动本地 PAC 服务。"))
        stop()
    }
}

/// Handles one bounded HTTP request on the PAC listener without accepting uploads or filesystem paths.
private final class PACRequest: @unchecked Sendable {
    private let connection: NWConnection
    private let path: String
    private let body: Data
    private let queue: DispatchQueue
    private let completed: @Sendable () -> Void
    private var buffer = Data()
    private var finished = false

    init(connection: NWConnection, path: String, script: String, queue: DispatchQueue, completed: @escaping @Sendable () -> Void) {
        self.connection = connection; self.path = path; body = Data(script.utf8)
        self.queue = queue; self.completed = completed
    }
    func start() {
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 3) { [self] in finish() }
        receive()
    }
    func cancel() { queue.async { [self] in finish() } }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [self] data, _, closed, error in
            guard !finished else { return }
            if let data { buffer.append(data) }
            guard buffer.count <= 8192, error == nil else { finish(); return }
            if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let text = String(decoding: buffer[..<range.lowerBound], as: UTF8.self)
                let parts = text.components(separatedBy: "\r\n").first?.split(separator: " ") ?? []
                let valid = parts.count == 3 && parts[1] == path && ["GET", "HEAD"].contains(String(parts[0]))
                let payload = valid ? body : Data()
                let status = valid ? "200 OK" : "404 Not Found"
                var response = Data("HTTP/1.1 \(status)\r\nContent-Type: application/x-ns-proxy-autoconfig\r\nContent-Length: \(payload.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
                if valid && parts[0] == "GET" { response.append(payload) }
                connection.send(content: response, completion: .contentProcessed { [self] _ in finish() })
            } else if closed { finish() } else { receive() }
        }
    }
    private func finish() {
        guard !finished else { return }
        finished = true; connection.cancel(); completed()
    }
}
