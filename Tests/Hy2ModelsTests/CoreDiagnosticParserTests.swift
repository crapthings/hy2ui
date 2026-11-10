import Foundation
import Testing
@testable import Hy2Models

/// Preserves fragmented core lines and emits only safe event categories in their observed order.
@Test func fragmentedCoreDiagnosticsPreserveOrderWithoutRawText() throws {
    var parser = CoreDiagnosticParser()
    parser.consume(Data("connected to hidden-address\nTUN proxy listening on interface utun100\nQUIC discon".utf8))
    #expect(parser.ready)
    parser.consume(Data("nected: secret-auth-token\nconnected to hidden-address\n".utf8))
    let events = parser.drain()
    #expect(events == [.connected, .disconnected, .connected])
    #expect(parser.ready && parser.drain().isEmpty)
    let encoded = try JSONEncoder().encode(events)
    #expect(!String(decoding: encoded, as: UTF8.self).contains("secret"))
    #expect(!events.map(\.message).joined().contains("hidden-address"))
}

/// Rejects an oversized whole line instead of interpreting its truncated suffix as a new log line.
@Test func oversizedCoreLineCannotForgeReadiness() {
    var parser = CoreDiagnosticParser()
    parser.consume(Data((String(repeating: "x", count: 9000) + "connected to fake\nTUN proxy listening on interface utun100\n").utf8))
    #expect(!parser.ready && parser.drain().isEmpty)
    parser.consume(Data("connected to real\n".utf8))
    #expect(parser.ready && parser.drain() == [.connected])
    parser.consume(Data("QUIC disconnected: hidden reason\n".utf8))
    #expect(!parser.ready && parser.drain() == [.disconnected])
}

/// Classifies per-flow TCP and UDP errors without relaying addresses or upstream error descriptions.
@Test func coreFlowErrorsBecomeSafeCategories() {
    var parser = CoreDiagnosticParser()
    parser.consume(Data("""
    TUN TCP source -> destination connect failed: private-message
    TUN TCP source -> destination transfer failed: private-message
    TUN UDP source -> destination session failed: private-message
    TUN UDP source -> destination send failed: private-message
    TUN UDP source -> destination receive failed: private-message
    unrelated raw secret

    """.utf8))
    #expect(parser.drain() == [.tcpConnectFailed, .tcpTransferFailed, .udpSessionFailed, .udpSendFailed, .udpReceiveFailed])
}

/// Bounds queued observations while retaining the most recent connection state during log bursts.
@Test func coreDiagnosticQueueIsBounded() {
    var parser = CoreDiagnosticParser()
    for _ in 0..<100 {
        parser.consume(Data("connected to hidden\nQUIC disconnected: hidden\n".utf8))
    }
    let events = parser.drain()
    #expect(events.count == 32 && events.last == .disconnected)
    #expect(!parser.ready)
}

/// Identifies benchmark-range destinations without leaking endpoints or matching error-text addresses.
@Test func syntheticTCPTargetDiagnosticsStayPrivate() throws {
    for host in ["198.18.0.2", "198.19.255.254"] {
        var parser = CoreDiagnosticParser()
        parser.consume(Data("TUN TCP 192.0.2.1:12345 -> \(host):443 connect failed: private-reason\n".utf8))
        let events = parser.drain()
        #expect(events == [.tcpSyntheticTargetFailed])
        let output = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        #expect(!output.contains(host) && !output.contains("private-reason"))
    }
    for target in ["198.17.0.1:443", "198.20.0.1:443", "[2001:db8::1]:443", "198.18.0.999:443", "198.18.0.1:invalid"] {
        var parser = CoreDiagnosticParser()
        parser.consume(Data("TUN TCP source -> \(target) connect failed: 198.18.0.2 private-reason\n".utf8))
        #expect(parser.drain() == [.tcpConnectFailed])
    }
}

/// Verifies allowlisted TCP diagnostics retain useful categories without exposing upstream text or targets.
@Test func structuredTCPFailuresAreClassifiedSafely() {
    let cases: [(String, LocalTunCoreEvent)] = [
        ("connect_timeout", .tcpConnectTimedOut), ("reset", .tcpReset), ("broken_pipe", .tcpBrokenPipe),
        ("transfer_timeout", .tcpTransferTimedOut), ("unexpected_eof", .tcpUnexpectedEOF),
        ("transfer_io", .tcpTransferFailed), ("capacity", .tcpCapacity)
    ]
    for (token, event) in cases {
        var parser = CoreDiagnosticParser()
        parser.consume(Data("HY2UI_TCP_ERROR \(token) (4 additional TUN errors suppressed)\n".utf8))
        #expect(parser.drain() == [event])
    }
    var parser = CoreDiagnosticParser()
    parser.consume(Data("HY2UI_TCP_ERROR secret-target-and-password\n".utf8))
    #expect(parser.drain().isEmpty)
}
