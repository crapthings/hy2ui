import Foundation
import Darwin

/// Describes a local helper transport failure without revealing request contents.
enum LocalTunTransportError: LocalizedError {
    case unavailable, untrustedPeer, closed, timedOut, invalidMessage
    var errorDescription: String? {
        switch self {
        case .unavailable: "本地增强模式后台不可用，请在增强模式设置中安装或修复后台。"
        case .untrustedPeer: "本地增强模式后台身份校验失败。"
        case .closed: "本地增强模式后台连接已中断，网络恢复状态尚未确认。"
        case .timedOut: "本地增强模式后台响应超时，请重试恢复。"
        case .invalidMessage: "本地增强模式后台返回了无效响应。"
        }
    }
}

/// Owns one nonblocking Unix connection and serializes its bounded request and event stream.
final class LocalTunTransport: @unchecked Sendable {
    let events: AsyncThrowingStream<LocalTunEvent, Error>
    private let continuation: AsyncThrowingStream<LocalTunEvent, Error>.Continuation
    private let socketPath: String
    private let expectedUID: uid_t
    private let initialRequest: LocalTunRequest
    private let startupTimeout: Duration
    private let queue = DispatchQueue(label: "dev.hy2ui.local-tun-transport", qos: .userInitiated)
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var shouldStop = false
    private var shouldAbort = false
    private var launched = false
    private var transmittedCommand: LocalTunCommand?

    var requestMayHaveBeenSent: Bool { lock.lock(); defer { lock.unlock() }; return transmittedCommand != nil }
    var startRequestMayHaveBeenSent: Bool { lock.lock(); defer { lock.unlock() }; return transmittedCommand == .start }

    init(socketPath: String, expectedUID: uid_t, request: LocalTunRequest, startupTimeout: Duration) {
        self.socketPath = socketPath
        self.expectedUID = expectedUID
        initialRequest = request
        self.startupTimeout = startupTimeout
        var sink: AsyncThrowingStream<LocalTunEvent, Error>.Continuation!
        events = AsyncThrowingStream(bufferingPolicy: .bufferingOldest(64)) { sink = $0 }
        continuation = sink
        continuation.onTermination = { [weak self] _ in self?.abort() }
    }

    func launch() {
        lock.lock()
        guard !launched else { lock.unlock(); return }
        launched = true
        lock.unlock()
        queue.async {
            do { try self.run(); self.continuation.finish() }
            catch { self.continuation.finish(throwing: error) }
        }
    }

    func requestStop() { lock.lock(); shouldStop = true; lock.unlock() }

    func abort() {
        lock.lock()
        shouldAbort = true
        // Only the I/O queue closes the descriptor, preventing reuse races with polling or writes.
        if descriptor >= 0 { shutdown(descriptor, SHUT_RDWR) }
        lock.unlock()
    }

    private func state() -> (stop: Bool, abort: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (shouldStop, shouldAbort)
    }

    private func run() throws {
        let socket = try openSocket()
        defer {
            lock.lock()
            if descriptor == socket { descriptor = -1 }
            Darwin.close(socket)
            lock.unlock()
        }
        let initial = state().stop ? LocalTunRequest(command: .stop) : initialRequest
        try send(initial, to: socket)
        lock.lock(); transmittedCommand = initial.command; lock.unlock()
        var sentStop = initial.command == .stop
        var deadline: ContinuousClock.Instant? = .now + startupTimeout
        var buffer = Data()
        while true {
            let flags = state()
            if flags.abort { throw CancellationError() }
            if flags.stop, !sentStop {
                try send(LocalTunRequest(command: .stop), to: socket)
                sentStop = true
                deadline = .now + .seconds(10)
            }
            if let deadline, ContinuousClock.now >= deadline { throw LocalTunTransportError.timedOut }
            if let newline = buffer.firstIndex(of: 10) {
                let bytes = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard let event = try? JSONDecoder().decode(LocalTunEvent.self, from: bytes) else {
                    throw LocalTunTransportError.invalidMessage
                }
                try event.interfaceSession?.validate()
                if case .dropped = continuation.yield(event) { throw LocalTunTransportError.invalidMessage }
                switch event.kind {
                case .ready:
                    if !sentStop { deadline = nil }
                case .stopped: return
                case .error: throw event.failure ?? LocalTunFailure(.unknown)
                case .log: break
                }
                continue
            }
            guard buffer.count < LocalTunWire.maxMessageBytes else { throw LocalTunProtocolError.messageTooLarge }
            guard try pollSocket(socket, events: Int16(POLLIN), milliseconds: 100) else { continue }
            var bytes = [UInt8](repeating: 0, count: min(4096, LocalTunWire.maxMessageBytes - buffer.count))
            let count = recv(socket, &bytes, bytes.count, 0)
            if count == 0 { throw LocalTunTransportError.closed }
            if count < 0 {
                if errno == EINTR || errno == EWOULDBLOCK || errno == EAGAIN { continue }
                throw LocalTunTransportError.closed
            }
            buffer.append(contentsOf: bytes.prefix(count))
        }
    }

    private func openSocket() throws -> Int32 {
        guard !state().abort else { throw CancellationError() }
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { throw LocalTunTransportError.unavailable }
        lock.lock(); descriptor = socket; let aborted = shouldAbort; lock.unlock()
        do {
            if aborted { throw CancellationError() }
            var enabled: Int32 = 1
            guard setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                throw LocalTunTransportError.unavailable
            }
            let flags = fcntl(socket, F_GETFL)
            guard flags >= 0, fcntl(socket, F_SETFL, flags | O_NONBLOCK) == 0 else { throw LocalTunTransportError.unavailable }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            let path = Array(socketPath.utf8CString)
            guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw LocalTunTransportError.unavailable }
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.map { UInt8(bitPattern: $0) }) }
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            if connected != 0 {
                guard errno == EINPROGRESS || errno == EAGAIN else { throw LocalTunTransportError.unavailable }
                let deadline = ContinuousClock.now + .seconds(3)
                while true {
                    if state().abort { throw CancellationError() }
                    guard ContinuousClock.now < deadline else { throw LocalTunTransportError.timedOut }
                    if try pollSocket(socket, events: Int16(POLLOUT), milliseconds: 100) { break }
                }
                var error: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(socket, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else { throw LocalTunTransportError.unavailable }
            }
            var user: uid_t = 0
            var group: gid_t = 0
            guard getpeereid(socket, &user, &group) == 0, user == expectedUID else { throw LocalTunTransportError.untrustedPeer }
            return socket
        } catch {
            lock.lock(); descriptor = -1; Darwin.close(socket); lock.unlock()
            throw error
        }
    }

    private func send(_ request: LocalTunRequest, to socket: Int32) throws {
        let data = try LocalTunMessageCodec.encode(request)
        let deadline = ContinuousClock.now + .seconds(3)
        var offset = 0
        while offset < data.count {
            if state().abort { throw CancellationError() }
            let count = data.withUnsafeBytes { Darwin.send(socket, $0.baseAddress!.advanced(by: offset), $0.count - offset, 0) }
            if count > 0 { offset += count; continue }
            guard count < 0, errno == EINTR || errno == EWOULDBLOCK || errno == EAGAIN,
                  ContinuousClock.now < deadline else { throw LocalTunTransportError.closed }
            _ = try pollSocket(socket, events: Int16(POLLOUT), milliseconds: 50)
        }
    }

    private func pollSocket(_ socket: Int32, events: Int16, milliseconds: Int32) throws -> Bool {
        var event = pollfd(fd: socket, events: events, revents: 0)
        let count = poll(&event, 1, milliseconds)
        if count < 0 {
            if errno == EINTR { return false }
            throw LocalTunTransportError.closed
        }
        return count > 0
    }
}
