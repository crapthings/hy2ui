import Foundation
import Testing
@testable import Hy2Models

/// Verifies typed detail frames, localization and IPC log encoding without retaining raw error strings.
struct CoreFlowDiagnosticTests {
    @Test func parsesDirectAndProxyFailures() throws {
        for (target, route) in [("127.0.0.1:443", "direct"), ("[2001:db8::1]:443", "proxy")] {
            let value = try #require(CoreFlowDiagnostic.parse("HY2UI_FLOW_ERROR tcp \(route) connect \(target) refused 61"))
            #expect(value.target == target && value.code == 61)
            #expect(value.render(detailed: true, localized: { $0 }).contains(target))
            #expect(!value.render(detailed: false, localized: { $0 }).contains(target))
            #expect(CoreFlowDiagnostic.fromLogMessage(value.logMessage) == value)
        }
    }
    @Test func preservesSuppressedCount() throws {
        let value = try #require(CoreFlowDiagnostic.parse("HY2UI_FLOW_ERROR udp proxy session [::1]:53 udp_disabled 0 (7 additional TUN errors suppressed)"))
        #expect(value.suppressed == 7 && value.reason == .udp_disabled)
    }
    @Test func rejectsUnknownOrUnboundedFields() {
        for line in [
            "HY2UI_FLOW_ERROR tcp proxy connect password@example.com:443 refused 61",
            "HY2UI_FLOW_ERROR tcp proxy connect example.com:443 refused 61",
            "HY2UI_FLOW_ERROR tcp proxy connect [::1]:0 refused 61",
            "HY2UI_FLOW_ERROR tcp proxy connect [invalid]:443 refused 61",
            "HY2UI_FLOW_ERROR tcp proxy connect 127.0.0.1:443 secret-server-message 61",
            "HY2UI_FLOW_ERROR tcp proxy connect 127.0.0.1:443 refused -1",
            "HY2UI_FLOW_ERROR tcp proxy connect 127.0.0.1:443 refused 70000",
            "HY2UI_FLOW_ERROR tcp proxy connect 127.0.0.1:443 refused 61 extra-secret",
            "HY2UI_FLOW_ERROR tcp proxy connect 127.0.0.1:443 refused 61 (1000000001 additional TUN errors suppressed)"
        ] { #expect(CoreFlowDiagnostic.parse(line) == nil) }
    }
    @Test func parserBoundsAndFragmentsDetails() throws {
        var parser = CoreDiagnosticParser()
        parser.consume(Data("HY2UI_FLOW_ERROR tcp proxy con".utf8))
        parser.consume(Data("nect 127.0.0.1:443 refused 61\n".utf8))
        #expect(parser.drainFlowDiagnostics().count == 1)
        #expect(parser.drain().isEmpty)
        for _ in 0..<40 { parser.consume(Data("HY2UI_FLOW_ERROR udp proxy session [::1]:53 udp_disabled 0\n".utf8)) }
        #expect(parser.drainFlowDiagnostics().count == 32)
        #expect(parser.drainFlowDiagnostics().isEmpty)
    }
    @Test func encodedLogRejectsMalformedEndpoint() throws {
        let value = try #require(CoreFlowDiagnostic.parse("HY2UI_FLOW_ERROR tcp direct connect 127.0.0.1:443 refused 61"))
        #expect(CoreFlowDiagnostic.fromLogMessage(value.logMessage.replacingOccurrences(of: "127.0.0.1:443", with: "secret-target")) == nil)
    }
    @Test func detailsSurviveHelperEventsAndLanguageChanges() throws {
        let diagnostic = try #require(CoreFlowDiagnostic.parse("HY2UI_FLOW_ERROR tcp proxy connect 127.0.0.1:443 refused 61"))
        let event = LocalTunEvent(kind: .log, message: diagnostic.logMessage)
        let encoded = try LocalTunMessageCodec.encode(event)
        let decoded = try JSONDecoder().decode(LocalTunEvent.self, from: Data(encoded.dropLast()))
        let message = try #require(decoded.message)
        let recovered = try #require(CoreFlowDiagnostic.fromLogMessage(message))
        let english = recovered.render(detailed: true) { AppLocalization.text($0, language: .english) }
        #expect(english.contains("Proxy") && english.contains("Target refused the connection") && english.contains("61"))
        let chinese = recovered.render(detailed: true) { AppLocalization.text($0, language: .chinese) }
        #expect(chinese.contains("目标拒绝连接"))
    }

    @Test func syntheticTargetsReceiveAnExplicitHint() throws {
        for (address, expected) in [("198.17.255.255", false), ("198.18.0.1", true), ("198.18.4.166", true), ("198.19.255.255", true), ("198.20.0.1", false)] {
            let value = try #require(CoreFlowDiagnostic.parse("HY2UI_FLOW_ERROR tcp proxy connect \(address):443 timeout 0"))
            #expect(value.isSyntheticTarget == expected)
            #expect(value.render(detailed: true, localized: { $0 }).contains("DNS 缓存") == expected)
        }
    }
    @Test func missingDirectIPv6IsNotReportedAsServerFailure() throws {
        let value = try #require(CoreFlowDiagnostic.parse("HY2UI_FLOW_ERROR tcp direct connect [2001:db8::1]:443 ipv6_unavailable 0"))
        #expect(value.render(detailed: true, localized: { $0 }).contains("本地网络没有 IPv6 直连出口"))
    }

}
