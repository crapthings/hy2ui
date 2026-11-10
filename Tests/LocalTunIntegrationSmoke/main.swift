import Foundation
import Darwin

/// Reports a smoke-test assertion without printing request contents or credentials.
private struct SmokeFailure: Error {
    let message: String
}

/// Owns a local socketpair and makes every test close both endpoints deterministically.
private final class SocketFixture {
    let helper: HelperSocket
    private(set) var peer: Int32

    init() throws {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw SmokeFailure(message: "socketpair creation failed")
        }
        helper = HelperSocket(descriptor: descriptors[0])
        peer = descriptors[1]
        var enabled: Int32 = 1
        _ = setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(peer, F_GETFL)
        guard flags >= 0, fcntl(peer, F_SETFL, flags | O_NONBLOCK) == 0 else {
            closePeer()
            throw SmokeFailure(message: "could not configure socketpair")
        }
    }

    deinit {
        helper.closeSocket()
        closePeer()
    }

    func closePeer() {
        guard peer >= 0 else { return }
        shutdown(peer, SHUT_RDWR)
        close(peer)
        peer = -1
    }

    func send(_ data: Data) throws {
        try Self.write(data, descriptor: peer)
    }

    static func write(_ data: Data, descriptor: Int32) throws {
        let deadline = ContinuousClock.now + .seconds(3)
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress!.advanced(by: offset), $0.count - offset, 0) }
            if count > 0 { offset += count; continue }
            guard count < 0, errno == EINTR || errno == EWOULDBLOCK || errno == EAGAIN,
                  ContinuousClock.now < deadline else { throw SmokeFailure(message: "bounded socket write failed") }
            var events = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            _ = poll(&events, 1, 20)
        }
    }

    func receiveLine() throws -> Data {
        let deadline = ContinuousClock.now + .seconds(3)
        var result = Data()
        while ContinuousClock.now < deadline {
            var byte: UInt8 = 0
            let count = recv(peer, &byte, 1, 0)
            if count == 1 {
                if byte == 10 { return result }
                result.append(byte)
                guard result.count < LocalTunWire.maxMessageBytes else { throw SmokeFailure(message: "unexpected event size") }
            } else if count == 0 { throw SmokeFailure(message: "unexpected event EOF") }
            else if errno == EINTR || errno == EWOULDBLOCK || errno == EAGAIN {
                var events = pollfd(fd: peer, events: Int16(POLLIN), revents: 0)
                _ = poll(&events, 1, 20)
            } else { throw SmokeFailure(message: "event read failed") }
        }
        throw SmokeFailure(message: "event read timed out")
    }
}

/// Stores a background fixture's result without sharing mutable state unsafely.
private final class WriteOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: Error?
    func record(_ error: Error) { lock.lock(); failure = error; lock.unlock() }
    func check() throws { lock.lock(); defer { lock.unlock() }; if let failure { throw failure } }
}

/// Exercises helper IPC boundaries without starting a daemon, changing DNS, or creating a TUN.
@main
private struct LocalTunIntegrationSmoke {
    static func main() throws {
        guard geteuid() != 0 else { throw SmokeFailure(message: "run these smoke tests as an ordinary user") }
        let privateText = "password=do-not-forward /private/secret.yaml"
        let sanitized = HelperFailure.safeFailure(HelperFailure(privateText))
        try expect(sanitized.code == .unknown && !sanitized.diagnostic.contains(privateText), "unknown helper error leaked raw text")
        let typed = LocalTunFailure(.workerExited, exitStatus: 9, terminatedBySignal: true)
        let preserved = HelperFailure.safeFailure(HelperFailure(privateText, failure: typed))
        try expect(preserved.code == .workerExited && preserved.exitStatus == 9, "typed process error lost its metadata")
        try verifiesPeerIdentity()
        try verifiesFrameBoundaries()
        try verifiesProcessRuleRequest()
        try verifiesIdleTimeoutAndEOF()
        try verifiesMalformedAndOversizedFrames()
        try verifiesEventDeliveryAndRootBoundary()
        print("Local TUN helper IPC smoke: peer identity, framing, timeout/EOF, bounds and privilege checks passed.")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw SmokeFailure(message: message) }
    }

    private static func verifiesPeerIdentity() throws {
        let fixture = try SocketFixture()
        try fixture.helper.authenticate(allowedUID: geteuid())
        do {
            try fixture.helper.authenticate(allowedUID: geteuid() ^ 1)
            throw SmokeFailure(message: "wrong peer UID was accepted")
        } catch is HelperFailure {}
    }

    private static func verifiesFrameBoundaries() throws {
        let fixture = try SocketFixture()
        let status = try LocalTunMessageCodec.encode(LocalTunRequest(command: .status))
        let stop = try LocalTunMessageCodec.encode(LocalTunRequest(command: .stop))
        try fixture.send(status + stop)
        let termination = HelperTermination()
        let first = try fixture.helper.readRequest(timeout: .seconds(1), termination: termination)
        let second = try fixture.helper.readRequest(timeout: .seconds(1), termination: termination)
        try expect(first?.command == .status && second?.command == .stop, "coalesced requests lost their message boundaries")
    }

    private static func verifiesProcessRuleRequest() throws {
        let fixture = try SocketFixture()
        let configuration = LocalTunConfiguration(host: "example.com", port: 443, password: "test-only",
            directProcesses: ["/Applications/Example.app/", "Helper*"])
        let request = try LocalTunMessageCodec.encode(LocalTunRequest(command: .start, configuration: configuration))
        try fixture.send(request)
        let decoded = try fixture.helper.readRequest(timeout: .seconds(1), termination: HelperTermination())
        try expect(decoded?.command == .start && decoded?.configuration == configuration, "process-rule request was rejected or changed")
    }

    private static func verifiesIdleTimeoutAndEOF() throws {
        let fixture = try SocketFixture()
        let termination = HelperTermination()
        let idle = try fixture.helper.readRequest(timeout: nil, termination: termination)
        try expect(idle == nil, "idle polling must return without claiming EOF")
        do {
            _ = try fixture.helper.readRequest(timeout: .zero, termination: termination)
            throw SmokeFailure(message: "expired request did not time out")
        } catch let error as HelperFailure {
            try expect(error.message.contains("超时"), "timeout was not reported distinctly")
        }
        fixture.closePeer()
        do {
            _ = try fixture.helper.readRequest(timeout: .seconds(1), termination: termination)
            throw SmokeFailure(message: "EOF was treated as idle polling")
        } catch let error as HelperFailure {
            try expect(error.message.contains("关闭"), "EOF was not reported distinctly")
        }
    }

    private static func verifiesMalformedAndOversizedFrames() throws {
        do {
            let fixture = try SocketFixture()
            try fixture.send(Data("{invalid-json}\n".utf8))
            do {
                _ = try fixture.helper.readRequest(timeout: .seconds(1), termination: HelperTermination())
                throw SmokeFailure(message: "malformed JSON was accepted")
            } catch is SmokeFailure { throw SmokeFailure(message: "malformed JSON was accepted") }
            catch {}
        }
        let fixture = try SocketFixture()
        let bytes = Data(repeating: 120, count: LocalTunWire.maxMessageBytes)
        let group = DispatchGroup()
        let outcome = WriteOutcome()
        let peer = dup(fixture.peer)
        guard peer >= 0 else { throw SmokeFailure(message: "could not duplicate fixture writer") }
        group.enter()
        DispatchQueue.global().async {
            defer { close(peer); group.leave() }
            do { try SocketFixture.write(bytes, descriptor: peer) }
            catch { outcome.record(error) }
        }
        defer {
            fixture.closePeer()
            _ = group.wait(timeout: .now() + 4)
        }
        do {
            _ = try fixture.helper.readRequest(timeout: .seconds(3), termination: HelperTermination())
            throw SmokeFailure(message: "oversized unterminated frame was accepted")
        } catch LocalTunProtocolError.messageTooLarge {}
        try expect(group.wait(timeout: .now() + 4) == .success, "oversized-frame writer did not finish")
        try outcome.check()
    }

    private static func verifiesEventDeliveryAndRootBoundary() throws {
        let fixture = try SocketFixture()
        try fixture.helper.send(LocalTunEvent(kind: .ready))
        let data = try fixture.receiveLine()
        let event = try JSONDecoder().decode(LocalTunEvent.self, from: data)
        try expect(event.kind == .ready && event.message == nil, "helper event framing changed")
        do {
            try TrustedInstallation.requireRoot()
            throw SmokeFailure(message: "ordinary user passed the root boundary")
        } catch is HelperFailure {}
    }
}
