import Foundation
import Testing
@testable import Hy2Models

/// Creates a nonsecret installation identity for command and manifest validation.
private func installationManifest() -> HelperInstallationManifest {
    HelperInstallationManifest(helperSHA256: String(repeating: "a", count: 64),
        workerSHA256: String(repeating: "b", count: 64), allowedUID: 501)
}

/// Rejects unbounded user IDs, unsupported schemas and malformed executable digests.
@Test
func helperManifestRejectsInvalidIdentity() throws {
    try installationManifest().validate()
    for manifest in [
        HelperInstallationManifest(version: 2, helperSHA256: String(repeating: "a", count: 64), workerSHA256: String(repeating: "b", count: 64), allowedUID: 501),
        HelperInstallationManifest(helperSHA256: "bad", workerSHA256: String(repeating: "b", count: 64), allowedUID: 501),
        HelperInstallationManifest(helperSHA256: String(repeating: "a", count: 64), workerSHA256: String(repeating: "b", count: 64), allowedUID: 0),
        HelperInstallationManifest(helperSHA256: String(repeating: "a", count: 64), workerSHA256: String(repeating: "b", count: 64), allowedUID: UInt32.max)
    ] { #expect(throws: (any Error).self) { try manifest.validate() } }
}

/// Roundtrips root-owned installation metadata without storing server credentials.
@Test
func helperManifestRoundtripsPropertyList() throws {
    let original = installationManifest()
    let encoded = try PropertyListEncoder().encode(original)
    let decoded = try PropertyListDecoder().decode(HelperInstallationManifest.self, from: encoded)
    #expect(decoded == original)
    try decoded.validate()
}

/// Protects shell metacharacters by encoding every argument as one single-quoted shell word.
@Test
func installerArgumentsPreserveLiteralPaths() {
    #expect(HelperInstallationCommand.shellQuote("hello world") == "'hello world'")
    #expect(HelperInstallationCommand.shellQuote("a'b") == "'a'\\''b'")
    #expect(HelperInstallationCommand.shellQuote("$(touch /tmp/example); `id`\nnext") == "'$(touch /tmp/example); `id`\nnext'")
}

/// Binds installation requests to one user and two expected executable digests before authorization.
@Test
func installerCommandBindsExpectedExecutables() throws {
    let script = try HelperInstallationCommand.authorizationScript(operation: .install,
        installerSource: "#!/bin/bash\nexit 0\n", appPath: "/Applications/Hy2 UI ' Demo.app", manifest: installationManifest())
    #expect(script.contains("with administrator privileges"))
    #expect(script.contains("'/usr/bin/env' '-i'"))
    #expect(script.contains("SUDO_UID=501"))
    #expect(script.contains("HY2_EXPECTED_HELPER_SHA256=" + String(repeating: "a", count: 64)))
    #expect(script.contains("HY2_EXPECTED_WORKER_SHA256=" + String(repeating: "b", count: 64)))
    #expect(script.contains(HelperInstallationCommand.cancellationMarker))
}

/// Rejects invalid application paths and oversized or non-Bash installer programs.
@Test
func installerCommandRejectsInvalidPayloads() throws {
    for path in ["relative.app", "/Applications/Other.txt", "/Applications/Bad\0.app"] {
        #expect(throws: (any Error).self) {
            try HelperInstallationCommand.authorizationScript(operation: .install,
                installerSource: "#!/bin/bash\nexit 0\n", appPath: path, manifest: installationManifest())
        }
    }
    for source in ["echo bad", "#!/bin/bash\n" + String(repeating: "x", count: 65_537)] {
        #expect(throws: (any Error).self) {
            try HelperInstallationCommand.authorizationScript(operation: .uninstall,
                installerSource: source, appPath: "/Applications/Hy2UI.app", manifest: installationManifest())
        }
    }
}

/// Keeps uninstallation independent of application-path and executable update arguments.
@Test
func uninstallCommandCarriesNoSourceApplicationArgument() throws {
    let script = try HelperInstallationCommand.authorizationScript(operation: .uninstall,
        installerSource: "#!/bin/bash\nexit 0\n", appPath: "/Applications/Hy2UI.app", manifest: installationManifest())
    #expect(!script.contains("HY2_EXPECTED_HELPER_SHA256"))
    #expect(!script.contains("/Applications/Hy2UI.app"))
}
