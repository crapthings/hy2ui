import Foundation
import JavaScriptCore
import Testing
@testable import Hy2Models

/// Verifies PAC decisions, process patterns and proxy ownership entirely with in-memory data.
struct RoutingTests {
    @Test func processPatternShapes() throws {
        #expect(ProcessRulePattern.matches("Chrome*", path: "/Applications/Google Chrome.app/Contents/MacOS/Chrome Helper"))
        #expect(ProcessRulePattern.matches("/Applications/Google Chrome.app/", path: "/Applications/Google Chrome.app/Contents/MacOS/Chrome Helper"))
        #expect(!ProcessRulePattern.matches("/Applications/Google Chrome.app/", path: "/Applications/Google Chrome.app.fake/executable"))
        #expect(ProcessRulePattern.matches("/usr/*/p?ng", path: "/usr/bin/ping"))
        #expect(!ProcessRulePattern.matches("chrome", path: "/usr/bin/Chrome"))
        for pattern in ["", "foo/bar", "evil\nname", " foo", "a,b", "a\\b"] {
            #expect(throws: (any Error).self) { try ProcessRulePattern.validate(pattern) }
        }
    }

    @Test func automaticPACDecisions() throws {
        var config = RoutingConfiguration(); config.mode = .generatedPAC; config.directDomains = ["example.com", "example.com"]
        let context = try #require(JSContext())
        context.evaluateScript(try PACScript.generate(configuration: config, httpPort: 18080))
        #expect(context.exception == nil)
        let function = try #require(context.objectForKeyedSubscript("FindProxyForURL"))
        for host in ["example.com", "sub.example.com", "EXAMPLE.COM", "EXAMPLE.COM.", "sub.example.com.", "localhost", "printer", "printer.local", "10.0.0.1", "172.31.2.3", "192.168.1.1", "[::1]", "fd00::1", "fe80::1", "::ffff:192.168.1.1", "0:0:0:0:0:0:0:1", "::ffff:c0a8:101", "0:0:0:0:0:ffff:192.168.1.1"] {
            #expect(function.call(withArguments: ["https://\(host)/", host])?.toString() == "DIRECT")
        }
        for host in ["badexample.com", "example.com.evil", "youtube.com", "104.20.23.154", "172.32.0.1", "[2606:4700:4700::1111]", "2001:db8::1"] {
            #expect(function.call(withArguments: ["https://\(host)/", host])?.toString() == "PROXY 127.0.0.1:18080")
        }
        config.bypassLocalNetworks = false
        context.evaluateScript(try PACScript.generate(configuration: config, httpPort: 18080))
        #expect(context.objectForKeyedSubscript("FindProxyForURL")?.call(withArguments: ["http://localhost/", "localhost"])?.toString() == "PROXY 127.0.0.1:18080")
    }

    @Test func rejectsInvalidPACAndCaptureCombinations() throws {
        var config = RoutingConfiguration(); config.mode = .externalPAC
        for url in ["file:///tmp/pac", "https://user:secret@example.com/pac", "https://example.com/#fragment", "", "javascript:evil()"] {
            config.pacURL = url
            #expect(throws: (any Error).self) { try config.validate() }
        }
        config.pacURL = "https://example.com/proxy.pac"; try config.validate()
        #expect(throws: (any Error).self) { try config.validateCapture(systemProxy: true, enhanced: true, backend: .localTun) }
        try config.validateCapture(systemProxy: true, enhanced: false, backend: .localTun)
        config.directProcesses = ["curl"]
        #expect(throws: (any Error).self) { try config.validateCapture(systemProxy: true, enhanced: false, backend: .localTun) }
        try config.validateCapture(systemProxy: false, enhanced: true, backend: .localTun)
        for domain in ["https://example.com", "*.example.com", "a\";evil()", ".com", "a..com"] {
            #expect(throws: (any Error).self) { try RoutingConfiguration.domain(domain) }
        }
    }

    @Test func restoresPACAsOneOwnedGroup() {
        let original: [String: Any] = ["ProxyAutoConfigEnable": 1, "ProxyAutoConfigURLString": "https://old.example/pac", "ProxyAutoConfigJavaScript": "old"]
        var installed = SystemProxyConfiguration.pac(url: "http://127.0.0.1:12345/random/pac")
        installed["ProxyAutoConfigJavaScript"] = ""
        let restored = ProxyOwnership.restore(current: installed, original: original, installed: installed)
        #expect(restored["ProxyAutoConfigURLString"] as? String == "https://old.example/pac")
        #expect(restored["ProxyAutoConfigJavaScript"] as? String == "old")
        var external = installed; external["ProxyAutoConfigURLString"] = "https://other.example/pac"
        let preserved = ProxyOwnership.restore(current: external, original: original, installed: installed)
        #expect(preserved["ProxyAutoConfigURLString"] as? String == "https://other.example/pac")
        #expect(preserved["ProxyAutoConfigJavaScript"] as? String == "")
        #expect(preserved["ProxyAutoConfigEnable"] as? Int == 1)
    }
}

/// Verifies activity shortcuts reuse persistent rules without removing rules shared by other processes.
struct ProcessRoutingPolicyTests {
    @Test func exactRuleRoundTrip() throws {
        let target = try ProcessRoutingTarget(path: "/usr/bin/curl")
        var config = RoutingConfiguration()
        #expect(ProcessRoutingPolicy.action(for: target, in: config) == .defaultRules)
        try ProcessRoutingPolicy.set(.direct, for: target, in: &config)
        try ProcessRoutingPolicy.set(.direct, for: target, in: &config)
        #expect(config.directProcesses == ["/usr/bin/curl"])
        #expect(ProcessRoutingPolicy.action(for: target, in: config) == .direct)
        try ProcessRoutingPolicy.set(.defaultRules, for: target, in: &config)
        #expect(config.directProcesses.isEmpty)
    }

    @Test func sharedRulesArePreserved() throws {
        let target = try ProcessRoutingTarget(path: "/Applications/Example.app/Contents/MacOS/Helper")
        for rule in ["Helper", "H*", "/Applications/Example.app/"] {
            var config = RoutingConfiguration(); config.directProcesses = [rule]
            try ProcessRoutingPolicy.set(.direct, for: target, in: &config)
            #expect(config.directProcesses == [rule])
            #expect(throws: (any Error).self) { try ProcessRoutingPolicy.set(.defaultRules, for: target, in: &config) }
            #expect(config.directProcesses == [rule])
        }
    }

    @Test func rejectedChangesLeaveConfigurationUntouched() throws {
        for path in ["curl", "/Applications/*/Helper", "/Applications/Example.app/", "", "/tmp/inject\nname"] {
            #expect(throws: (any Error).self) { try ProcessRoutingTarget(path: path) }
        }
        let target = try ProcessRoutingTarget(path: "/usr/bin/curl")
        var config = RoutingConfiguration(); config.directProcesses = (0..<64).map { "process\($0)" }
        let original = config
        #expect(throws: (any Error).self) { try ProcessRoutingPolicy.set(.direct, for: target, in: &config) }
        #expect(config == original)
    }
}
