import Foundation
import Darwin

/// Restricts a Unix socket connection to bounded newline messages from one allowed local user.
final class HelperSocket {
    let descriptor: Int32
    private var buffered = Data()
    private var closed = false

    init(descriptor: Int32) {
        self.descriptor = descriptor
        var enabled: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(descriptor, F_GETFL)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
    }

    deinit { closeSocket() }

    func closeSocket() {
        guard !closed else { return }
        closed = true
        shutdown(descriptor, SHUT_RDWR)
        close(descriptor)
    }

    func authenticate(allowedUID: uid_t) throws {
        var user: uid_t = 0
        var group: gid_t = 0
        guard getpeereid(descriptor, &user, &group) == 0, user == allowedUID else {
            throw HelperFailure("不允许此用户访问本地增强模式服务。")
        }
    }

    func hasPendingInputOrClosed() -> Bool {
        if !buffered.isEmpty { return true }
        var probe: UInt8 = 0
        let count = recv(descriptor, &probe, 1, MSG_PEEK | MSG_DONTWAIT)
        return count >= 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)
    }

    func readRequest(timeout: Duration?, termination: HelperTermination) throws -> LocalTunRequest? {
        let deadline = timeout.map { ContinuousClock.now + $0 }
        while !termination.isRequested {
            if let newline = buffered.firstIndex(of: 10) {
                let line = buffered[..<newline]
                buffered.removeSubrange(...newline)
                return try LocalTunMessageCodec.decodeRequest(Data(line))
            }
            guard buffered.count < LocalTunWire.maxMessageBytes else { throw LocalTunProtocolError.messageTooLarge }
            if let deadline, ContinuousClock.now >= deadline { throw HelperFailure("本地增强模式请求超时。") }
            var events = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let result = poll(&events, 1, 100)
            if result < 0 {
                if errno == EINTR { continue }
                throw HelperFailure("本地增强模式连接不可用。")
            }
            if result == 0 { if deadline != nil { continue }; return nil }
            var bytes = [UInt8](repeating: 0, count: min(4096, LocalTunWire.maxMessageBytes - buffered.count))
            let count = recv(descriptor, &bytes, bytes.count, 0)
            if count == 0 { throw HelperFailure("本地增强模式连接已关闭。") }
            if count < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }
                throw HelperFailure("无法读取本地增强模式请求。")
            }
            buffered.append(contentsOf: bytes.prefix(count))
        }
        throw CancellationError()
    }

    func send(_ event: LocalTunEvent) throws {
        let data = try LocalTunMessageCodec.encode(event)
        let deadline = ContinuousClock.now + .seconds(2)
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { bytes in
                Darwin.send(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
            }
            if count > 0 { offset += count; continue }
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR), ContinuousClock.now < deadline {
                var events = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                _ = poll(&events, 1, 50)
                continue
            }
            throw HelperFailure("无法写入本地增强模式事件。")
        }
    }
}
