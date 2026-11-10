import Foundation
import Darwin

/// Records mock installer state behind a lock so background inspection remains deterministic.
private final class InstallerFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var value = HelperInstallationStatus.notInstalled
    private var captured: [String] = []
    private var probes = 0
    private var firstEntered = false
    var suspendFirstProbe = false
    let probeRelease = DispatchSemaphore(value: 0)

    var scripts: [String] { lock.lock(); defer { lock.unlock() }; return captured }
    var firstProbeEntered: Bool { lock.lock(); defer { lock.unlock() }; return firstEntered }

    func set(_ status: HelperInstallationStatus) { lock.lock(); value = status; lock.unlock() }
    func record(_ script: String) { lock.lock(); captured.append(script); lock.unlock() }
    func status() -> HelperInstallationStatus {
        lock.lock()
        probes += 1
        let held = probes == 1 && suspendFirstProbe
        let result = value
        if held { firstEntered = true }
        lock.unlock()
        if held { _ = probeRelease.wait(timeout: .now() + 5) }
        return result
    }
}

/// Supplies a bounded authorization gate for testing duplicate UI actions.
private actor InstallerGate {
    var entered = false
    private var released = false
    func wait() async throws {
        entered = true
        let deadline = ContinuousClock.now + .seconds(5)
        while !released {
            guard ContinuousClock.now < deadline else { throw HelperInstallationError.failed("mock authorization timed out") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    func release() { released = true }
}

/// Exercises UI installation with injected authorization instead of invoking administrator commands.
@main
private struct HelperInstallerSmoke {
    private static let app = URL(fileURLWithPath: "/Applications/Hy2 UI ' Demo.app")

    @MainActor
    static func main() async throws {
        try await successfulInstallAndUninstall()
        try await cancelledAuthorizationPreservesInstallation()
        try await failedInstallPreservesOldVersion()
        try await repeatedActionIsCoalesced()
        try await staleProbeCannotOverwriteCompletedInstall()
        print("Helper installer mock smoke: install/uninstall, cancellation, failure, duplicate actions and stale probes passed.")
    }

    @MainActor
    private static func successfulInstallAndUninstall() async throws {
        let fixture = InstallerFixture()
        let dependencies = makeDependencies(fixture) { _ in fixture.set(.current) }
        let manager = HelperInstallationManager(application: app, dependencies: dependencies)
        await manager.refresh()
        try require(manager.status == .notInstalled, "fresh status")
        try require(await manager.perform(.install), "install success")
        try require(manager.status == .current && !manager.isBusy && !manager.failed, "installed state")
        let script = try unwrap(fixture.scripts.first)
        try require(script.contains("with administrator privileges"), "native authorization is requested")
        try require(script.contains("HY2_EXPECTED_HELPER_SHA256"), "executable snapshot is bound")
        let output = URL(fileURLWithPath: ".build/helper-installer-tests/authorization.applescript")
        try script.write(to: output, atomically: true, encoding: .utf8)
        let uninstallDependencies = makeDependencies(fixture) { _ in fixture.set(.notInstalled) }
        let uninstall = HelperInstallationManager(application: app, dependencies: uninstallDependencies)
        await uninstall.refresh()
        try require(uninstall.canUninstall, "uninstall availability")
        try require(await uninstall.perform(.uninstall), "uninstall success")
        try require(uninstall.status == .notInstalled, "uninstalled state")
    }

    @MainActor
    private static func cancelledAuthorizationPreservesInstallation() async throws {
        let fixture = InstallerFixture()
        let manager = HelperInstallationManager(application: app, dependencies: makeDependencies(fixture) { _ in
            throw HelperInstallationError.cancelled
        })
        await manager.refresh()
        try require(!(await manager.perform(.install)), "cancelled operation")
        try require(manager.status == .notInstalled && !manager.failed && !manager.isBusy, "cancel preserves state")
        try require(fixture.scripts.count == 1, "one authorization request")
    }

    @MainActor
    private static func failedInstallPreservesOldVersion() async throws {
        let fixture = InstallerFixture()
        fixture.set(.legacy)
        let manager = HelperInstallationManager(application: app, dependencies: makeDependencies(fixture) { _ in
            throw HelperInstallationError.failed("mock recovery failure")
        })
        await manager.refresh()
        try require(!(await manager.perform(.install)), "failed operation")
        try require(manager.status == .legacy && manager.failed && manager.canUninstall, "failure retains old installation")
        try require(manager.message == "mock recovery failure", "failure is visible")
    }

    @MainActor
    private static func repeatedActionIsCoalesced() async throws {
        let fixture = InstallerFixture()
        let gate = InstallerGate()
        let manager = HelperInstallationManager(application: app, dependencies: makeDependencies(fixture) { _ in
            try await gate.wait()
            fixture.set(.current)
        })
        let first = Task { await manager.perform(.install) }
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await gate.entered) {
            guard ContinuousClock.now < deadline else { throw HelperInstallationError.failed("mock did not enter authorization") }
            try await Task.sleep(for: .milliseconds(5))
        }
        try require(manager.isBusy, "busy while awaiting user")
        try require(!(await manager.perform(.uninstall)), "duplicate action rejected")
        try require(fixture.scripts.count == 1, "no second administrator prompt")
        await gate.release()
        try require(await first.value, "first action completed")
    }

    @MainActor
    private static func staleProbeCannotOverwriteCompletedInstall() async throws {
        let fixture = InstallerFixture()
        fixture.set(.legacy)
        fixture.suspendFirstProbe = true
        let manager = HelperInstallationManager(application: app, dependencies: makeDependencies(fixture) { _ in fixture.set(.current) })
        let stale = Task { await manager.refresh() }
        let deadline = ContinuousClock.now + .seconds(3)
        while !fixture.firstProbeEntered {
            guard ContinuousClock.now < deadline else { throw HelperInstallationError.failed("mock probe did not start") }
            try await Task.sleep(for: .milliseconds(5))
        }
        try require(await manager.perform(.install), "install during old probe")
        fixture.probeRelease.signal()
        await stale.value
        try require(manager.status == .current, "old probe result ignored")
    }

    private static func makeDependencies(_ fixture: InstallerFixture,
        authorize: @escaping @Sendable (String) async throws -> Void) -> HelperInstallationDependencies {
        HelperInstallationDependencies(snapshot: { application in
            HelperInstallationSnapshot(application: application,
                manifest: HelperInstallationManifest(helperSHA256: String(repeating: "a", count: 64),
                    workerSHA256: String(repeating: "b", count: 64), allowedUID: 501))
        }, status: { _ in fixture.status() }, authorize: { script in
            fixture.record(script)
            try await authorize(script)
        })
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw HelperInstallationError.failed("Test failed: " + message) }
    }

    private static func unwrap<Value>(_ value: Value?) throws -> Value {
        guard let value else { throw HelperInstallationError.failed("Test fixture value missing") }
        return value
    }
}
