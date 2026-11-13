import Foundation
import Testing
@testable import Hy2Models

/// Verifies native rule semantics, unsupported-input rejection and separation from capture settings.
struct NativeClientRoutingTests {
    @Test func orderedRulesAndFinalAreSentToCore() throws {
        var routing = RoutingConfiguration()
        routing.directProcesses = ["Browser"]
        routing.addressRules = [try AddressRule(target: "ads.example", action: .reject, domainMatch: .exact),
                                try AddressRule(target: "10.0.0.0/8", action: .proxy)]
        routing.finalAction = .direct
        let object = try NativeClientRouting.object(for: routing)
        let rules = try #require(object["rules"] as? [String])
        #expect(Array(rules.prefix(3)) == ["direct(process-name:Browser)", "reject(ads.example)", "direct(10.0.0.0/8)"])
        #expect(object["default"] as? String == "direct")
        routing.rulePreferences["process:Browser"] = RulePreferences(enabled: false)
        #expect(!(try NativeClientRouting.object(for: routing)["rules"] as! [String]).contains("direct(process-name:Browser)"))
    }

    @Test func modesDoNotAccidentallyRunSavedRules() throws {
        var routing = RoutingConfiguration()
        routing.directProcesses = ["unsupported*"]
        for mode in [RequestRoutingMode.global, .direct] {
            routing.requestMode = mode
            let object = try NativeClientRouting.object(for: routing)
            #expect((object["rules"] as? [String])?.isEmpty == true)
            #expect(object["default"] as? String == (mode == .global ? "proxy" : "direct"))
        }
        routing.requestMode = .rules
        #expect(throws: (any Error).self) { try NativeClientRouting.object(for: routing) }
        routing.directProcesses = []
        routing.addressRules = [try AddressRule(target: "example", action: .direct, domainMatch: .keyword)]
        #expect(throws: (any Error).self) { try NativeClientRouting.object(for: routing) }
    }

    @Test func tunCannotSilentlyIgnoreProcessRules() throws {
        var routing = RoutingConfiguration(); routing.directProcesses = ["Browser"]
        try routing.validateCapture(systemProxy: true, enhanced: false, backend: .localTun)
        #expect(throws: (any Error).self) { try routing.validateCapture(systemProxy: true, enhanced: true, backend: .localTun) }
        let data = try NativeClientRouting.applying(to: Data(#"{"auth":"test","desktopBypassLocalNetworks":true}"#.utf8), routing: routing)
        let object = try DesktopCoreConfiguration.object(data)
        #expect(object["desktopBypassLocalNetworks"] == nil)
        #expect(object["auth"] as? String == "test")
        #expect(object["routing"] != nil)
    }
}
