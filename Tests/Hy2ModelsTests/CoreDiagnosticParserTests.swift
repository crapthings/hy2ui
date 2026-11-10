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
