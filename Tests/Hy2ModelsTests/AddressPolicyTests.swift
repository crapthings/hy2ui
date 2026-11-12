import Foundation
import JavaScriptCore
import CFNetwork
import Testing
@testable import Hy2Models

/// Checks dual-stack address rules, legacy migration and capture-specific defaults without system network operations.
struct AddressPolicyTests {
    @Test func canonicalPrefixesAndBoundaries() throws {
        let net = try IPNetwork("192.168.50.123/24")
        #expect(net.cidr == "192.168.50.0/24")
        #expect(net.mask == "255.255.255.0")
        #expect(net.contains(try IPNetwork("192.168.50.255")))
        #expect(!net.contains(try IPNetwork("192.168.51.0")))
        #expect(try IPNetwork("2001:DB8::123/32").cidr == "2001:db8::/32")
        #expect(try IPNetwork("::/0").contains(IPNetwork("ffff::1")))
        for invalid in ["1.2.3.999", "192.168.1.1/-1", "1.1.1.1/33", "::/129", "::/", "1.1.1.1/2/3", "fe80::1%en1"] {
            #expect(throws: (any Error).self) { try IPNetwork(invalid) }
        }
    }
    @Test func canonicalAddressRulesRejectMalformedLiterals() throws {
        #expect(try AddressRule(target: " EXAMPLE.COM ", action: .direct).target == "example.com")
        #expect(try AddressRule(target: "192.0.2.123/24", action: .proxy).target == "192.0.2.0/24")
        for invalid in ["1.2.3.999", "https://example.com", "*.example.com", "::/999", "2001:db8:::1"] {
            #expect(throws: (any Error).self) { try AddressRule(target: invalid, action: .direct) }
        }
    }
    @Test func oldPreferencesRetainRulesAndLocalDefault() throws {
        let bytes = Data(#"{"version":1,"mode":"manual","pacURL":"","directDomains":["example.com"],"bypassLocalNetworks":true,"directProcesses":["curl"]}"#.utf8)
        let old = try JSONDecoder().decode(RoutingConfiguration.self, from: bytes)
        #expect(old.directDomains == ["example.com"] && old.directProcesses == ["curl"])
        #expect(old.addressRules.isEmpty && old.bypassLocalNetworks)
        #expect(old.finalAction == .proxy)
        #expect(try JSONDecoder().decode(RoutingConfiguration.self, from: JSONEncoder().encode(old)) == old)
    }
    @Test func pacUsesMostSpecificRulesWithoutResolvingDomains() throws {
        var config = RoutingConfiguration(); config.mode = .generatedPAC
        config.addressRules = try [AddressRule(target: "example.com", action: .direct), AddressRule(target: "api.example.com", action: .proxy), AddressRule(target: "203.0.113.0/24", action: .direct), AddressRule(target: "203.0.113.9", action: .proxy), AddressRule(target: "2001:db8::/32", action: .direct)]
        let context = try #require(JSContext())
        let script = try PACScript.generate(configuration: config, httpPort: 18080)
        #expect(!script.contains("dnsResolve"))
        context.evaluateScript(script); #expect(context.exception == nil)
        let function = try #require(context.objectForKeyedSubscript("FindProxyForURL"))
        for host in ["example.com", "www.example.com", "203.0.113.8", "[2001:db8::1]", "router.home.arpa"] {
            #expect(function.call(withArguments: ["https://\(host)/", host])?.toString() == "DIRECT")
        }
        for host in ["api.example.com", "v1.api.example.com", "203.0.113.9", "198.18.4.166", "100.64.1.2", "elsewhere.com"] {
            #expect(function.call(withArguments: ["https://\(host)/", host])?.toString() == "PROXY 127.0.0.1:18080")
        }
        config.addressRules = try [AddressRule(target: "192.168.0.0/16", action: .proxy)]
        context.evaluateScript(try PACScript.generate(configuration: config, httpPort: 18080))
        #expect(function.call(withArguments: ["http://192.168.1.1", "192.168.1.1"])?.toString() == "DIRECT")
    }
    @Test func manualBypassIsOwnedAndRestorable() {
        let local = SystemProxyConfiguration.manual(httpPort: 18080, socksPort: 11080)
        #expect(local["ExceptionsList"] as? [String] == LocalNetworkPolicy.proxyExceptions)
        let none = SystemProxyConfiguration.manual(httpPort: 18080, socksPort: 11080, bypassLocalNetworks: false)
        #expect(none["ExceptionsList"] as? [String] == [])
        let original: [String: Any] = ["ExceptionsList": ["company.internal"], "ExcludeSimpleHostnames": 0]
        let restored = ProxyOwnership.restore(current: local, original: original, installed: local)
        #expect(restored["ExceptionsList"] as? [String] == ["company.internal"])
        var external = local; external["ExceptionsList"] = ["other.internal"]
        #expect(ProxyOwnership.restore(current: external, original: original, installed: local)["ExceptionsList"] as? [String] == ["other.internal"])
    }
    @Test func helperAcceptsOnlyBoundedIPRulesAndOptionalDefaults() throws {
        let payload = LocalTunConfiguration(host: "example.com", port: 443, password: "test", bypassLocalNetworks: true, addressRules: ["direct,203.0.113.0/24", "proxy,2001:db8::1"])
        let data = try LocalTunMessageCodec.encode(LocalTunRequest(command: .start, configuration: payload))
        #expect(try LocalTunMessageCodec.decodeRequest(data).configuration == payload)
        let invalid = LocalTunConfiguration(host: "example.com", port: 443, password: "test", addressRules: ["direct,example.com"])
        #expect(throws: (any Error).self) { try invalid.validate() }
        let legacy = LocalTunConfiguration(host: "example.com", port: 443, password: "test")
        #expect(legacy.bypassLocalNetworks == nil && legacy.addressRules == nil && legacy.finalDirect == nil)
        let direct = LocalTunConfiguration(host: "example.com", port: 443, password: "test", finalDirect: true)
        let directData = try LocalTunMessageCodec.encode(LocalTunRequest(command: .start, configuration: direct))
        #expect(try LocalTunMessageCodec.decodeRequest(directData).configuration == direct)
    }
    @Test func localDNSNeverUsesSyntheticResolversOrRootSuffix() {
        #expect(LocalDNSPolicy.domains(search: [".", "", "corp.example", "CORP.EXAMPLE.", "a/b", "com"]) == ["com", "corp.example", "home.arpa"])
        #expect(LocalDNSPolicy.servers(["192.168.50.1", "198.18.0.2", "127.0.0.1", "::1", "bad", "2606:4700::1111"]) == ["192.168.50.1", "2606:4700::1111"])
    }
    @Test func fixedProxyExceptionsPreservePublicIPv6AndLocalIPv4() throws {
        let settings = SystemProxyConfiguration.manual(httpPort: 18080, socksPort: 11080)
        for host in ["10.1.2.3", "192.168.50.1", "printer.local", "router.home.arpa"] {
            let url = try #require(URL(string: "http://\(host)/"))
            let selected = CFNetworkCopyProxiesForURL(url as CFURL, settings as CFDictionary).takeRetainedValue() as! [[String: Any]]
            #expect(selected.first?[kCFProxyTypeKey as String] as? String == kCFProxyTypeNone as String)
        }
        for host in ["example.com", "198.18.4.166", "100.64.1.1", "[2606:4700::1111]"] {
            let url = try #require(URL(string: "http://\(host)/"))
            let selected = CFNetworkCopyProxiesForURL(url as CFURL, settings as CFDictionary).takeRetainedValue() as! [[String: Any]]
            #expect(selected.first?[kCFProxyTypeKey as String] as? String == kCFProxyTypeHTTP as String)
        }
    }
    @Test func globalProxyDelegatesIPv6AndSimpleNamesToPAC() throws {
        var settings = SystemProxyConfiguration.manual(httpPort: 18080, socksPort: 11080)
        settings["ProxyAutoConfigEnable"] = 1
        settings["ProxyAutoConfigURLString"] = "http://127.0.0.1:12345/test.pac"
        #expect(settings["ExcludeSimpleHostnames"] == nil)
        for host in ["nas", "[fd00::1]", "[2606:4700::1111]"] {
            let url = try #require(URL(string: "http://\(host)/"))
            let selected = CFNetworkCopyProxiesForURL(url as CFURL, settings as CFDictionary).takeRetainedValue() as! [[String: Any]]
            #expect(selected.first?[kCFProxyTypeKey as String] as? String == kCFProxyTypeAutoConfigurationURL as String)
        }
    }
    @Test func removedSimpleHostFlagRestoresOnlyWhileAbsent() {
        let original: [String: Any] = ["ExcludeSimpleHostnames": 1]
        #expect(ProxyOwnership.restore(current: [:], original: original, installed: [:], removedKeys: ["ExcludeSimpleHostnames"])["ExcludeSimpleHostnames"] as? Int == 1)
        #expect(ProxyOwnership.restore(current: ["ExcludeSimpleHostnames": 0], original: original, installed: [:], removedKeys: ["ExcludeSimpleHostnames"])["ExcludeSimpleHostnames"] as? Int == 0)
    }
    @Test func desktopCaptureMetadataDoesNotReachStrictCore() throws {
        let input = Data(#"{"server":"example.com:443","auth":"test","desktopBypassLocalNetworks":true,"desktopAddressRules":["direct,203.0.113.0/24"],"desktopDirectProcesses":["curl"],"desktopFinalDirect":true}"#.utf8)
        let core = try #require(JSONSerialization.jsonObject(with: DesktopCoreConfiguration.coreOnly(input)) as? [String: Any])
        #expect(core["server"] as? String == "example.com:443")
        #expect(core["desktopBypassLocalNetworks"] == nil && core["desktopAddressRules"] == nil && core["desktopDirectProcesses"] == nil)
        #expect(core["desktopFinalDirect"] == nil)
        #expect(try DesktopCoreConfiguration.finalDirect(in: input))
        #expect(try DesktopCoreConfiguration.finalDirect(in: Data("{}".utf8)) == false)
        #expect(throws: (any Error).self) {
            try DesktopCoreConfiguration.finalDirect(in: Data(#"{"desktopFinalDirect":"true"}"#.utf8))
        }
        #expect(try DesktopCoreConfiguration.coreOnly(Data()) == Data())
    }

    /// Rejects missing or malformed desktop metadata instead of silently choosing a different routing policy.
    @Test func desktopCaptureMetadataRequiresAnExplicitBoolean() throws {
        #expect(try DesktopCoreConfiguration.bypassLocalNetworks(in: Data(#"{"desktopBypassLocalNetworks":false}"#.utf8)) == false)
        #expect(try DesktopCoreConfiguration.bypassLocalNetworks(in: Data(#"{"desktopBypassLocalNetworks":true}"#.utf8)))
        for json in ["{}", "[]", #"{"desktopBypassLocalNetworks":1}"#, #"{"desktopBypassLocalNetworks":"false"}"#] {
            #expect(throws: (any Error).self) { try DesktopCoreConfiguration.bypassLocalNetworks(in: Data(json.utf8)) }
        }
        #expect(throws: (any Error).self) { try DesktopCoreConfiguration.object(Data("[]".utf8)) }
        #expect(throws: (any Error).self) { try DesktopCoreConfiguration.object(Data()) }
        let object = try DesktopCoreConfiguration.object(Data(#"{"server":"example.com:443"}"#.utf8))
        #expect(object["server"] as? String == "example.com:443")
    }

}
