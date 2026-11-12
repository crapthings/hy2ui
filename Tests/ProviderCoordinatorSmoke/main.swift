import Foundation

/// Reports an assertion failure in the provider lifecycle smoke test.
enum ProviderSmokeError: Error, Equatable { case failed(String), fixture }

/// Asserts a provider lifecycle invariant.
func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw ProviderSmokeError.failed(message) }
}

/// Waits for a fixture event without blocking the coordinator or callback queue.
func waitFor(_ name: String, _ predicate: () -> Bool) throws {
    let deadline = Date().addingTimeInterval(4)
    while Date() < deadline {
        if predicate() { return }
        usleep(5_000)
    }
    throw ProviderSmokeError.failed("timed out: \(name)")
}

/// Records asynchronous completion results for deterministic assertions.
final class CompletionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Result<Void, Error>] = []
    func receive(_ result: Result<Void, Error>) { lock.lock(); values.append(result); lock.unlock() }
    func count() -> Int { lock.lock(); defer { lock.unlock() }; return values.count }
    func value() -> Result<Void, Error>? { lock.lock(); defer { lock.unlock() }; return values.first }
    func wait() throws -> Result<Void, Error> {
        try waitFor("completion") { self.count() > 0 }
        return value()!
    }
}

/// Supplies a harmless packet-flow placeholder for coordinator-only tests.
final class EmptyProviderFlow: ExperimentalPacketFlow {
    func readPackets(completion: @escaping ([Data], [Int32]) -> Void) {}
    func writePackets(_ packets: [Data], families: [Int32]) -> Bool { true }
}

/// Holds packet-engine callbacks until the test explicitly advances each phase.
final class ManualProviderEngine: ExperimentalProviderEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var starts: [(Result<Void, Error>) -> Void] = []
    private var attaches: [(Result<Void, Error>) -> Void] = []
    private var stops: [(Result<Void, Error>) -> Void] = []
    let failure: (Error) -> Void
    init(failure: @escaping (Error) -> Void) { self.failure = failure }

    func start(configuration: Data, completion: @escaping (Result<Void, Error>) -> Void) {
        lock.lock(); starts.append(completion); lock.unlock()
    }
    func attach(flow: ExperimentalPacketFlow, completion: @escaping (Result<Void, Error>) -> Void) {
        lock.lock(); attaches.append(completion); lock.unlock()
    }
    func stop(completion: @escaping (Result<Void, Error>) -> Void) {
        lock.lock(); stops.append(completion); lock.unlock()
    }
    func counts() -> (Int, Int, Int) { lock.lock(); defer { lock.unlock() }; return (starts.count, attaches.count, stops.count) }
    func completeStart(_ result: Result<Void, Error>) { lock.lock(); let callback = starts[0]; lock.unlock(); callback(result) }
    func completeAttach(_ result: Result<Void, Error>) { lock.lock(); let callback = attaches[0]; lock.unlock(); callback(result) }
    func completeStop(_ index: Int, _ result: Result<Void, Error>) { lock.lock(); let callback = stops[index]; lock.unlock(); callback(result) }
}

/// Holds settings callbacks so tests can reorder, fail and replay system operations.
final class ManualProviderSystem: ExperimentalProviderSystem, @unchecked Sendable {
    let packetFlow: ExperimentalPacketFlow = EmptyProviderFlow()
    private let lock = NSLock()
    private var installs: [(Result<Void, Error>) -> Void] = []
    private var clears: [(Result<Void, Error>) -> Void] = []
    private var cancellations = 0
    func installSettings(completion: @escaping (Result<Void, Error>) -> Void) {
        lock.lock(); installs.append(completion); lock.unlock()
    }
    func clearSettings(completion: @escaping (Result<Void, Error>) -> Void) {
        lock.lock(); clears.append(completion); lock.unlock()
    }
    func cancelTunnel(error: Error) { lock.lock(); cancellations += 1; lock.unlock() }
    func counts() -> (Int, Int, Int) { lock.lock(); defer { lock.unlock() }; return (installs.count, clears.count, cancellations) }
    func completeInstall(_ index: Int, _ result: Result<Void, Error>) { lock.lock(); let callback = installs[index]; lock.unlock(); callback(result) }
    func completeClear(_ index: Int, _ result: Result<Void, Error>) { lock.lock(); let callback = clears[index]; lock.unlock(); callback(result) }
}

/// Creates and retains the manual engines for multiple coordinator sessions.
final class ProviderEngineFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var engines: [ManualProviderEngine] = []
    func make(failure: @escaping (Error) -> Void) -> ExperimentalProviderEngine {
        let engine = ManualProviderEngine(failure: failure)
        lock.lock(); engines.append(engine); lock.unlock()
        return engine
    }
    func count() -> Int { lock.lock(); defer { lock.unlock() }; return engines.count }
    func engine(_ index: Int) -> ManualProviderEngine { lock.lock(); defer { lock.unlock() }; return engines[index] }
}

/// Runs the provider coordinator against controlled callbacks without installing network settings.
@main enum ProviderCoordinatorSmoke {
    static func coordinator(system: ManualProviderSystem, factory: ProviderEngineFactory,
                            cleanupFailures: CompletionProbe) -> ExperimentalProviderCoordinator {
        ExperimentalProviderCoordinator(system: system, callbackQueue: DispatchQueue(label: "provider.test.\(UUID())"),
                                        engineFactory: { factory.make(failure: $0) },
                                        onCleanupFailure: { cleanupFailures.receive(.failure($0)) })
    }

    static func expectProviderError(_ result: Result<Void, Error>, _ expected: ExperimentalProviderError) throws {
        guard case let .failure(error) = result, error as? ExperimentalProviderError == expected else {
            throw ProviderSmokeError.failed("unexpected provider result")
        }
    }

    static func main() throws {
        let ipv4Endpoint = try ExperimentalEndpointCandidate(server: "203.0.113.1:443", tlsServerName: "example.test")
        try require(ipv4Endpoint.address == "203.0.113.1" && ipv4Endpoint.port == 443 &&
                    ipv4Endpoint.exclusionPrefixLength == 32 && ipv4Endpoint.tlsServerName == "example.test",
                    "incorrect IPv4 candidate")
        let ipv6Endpoint = try ExperimentalEndpointCandidate(server: "[2001:db8::1]:8443", tlsServerName: "example.test")
        try require(ipv6Endpoint.address == "2001:db8::1" && ipv6Endpoint.port == 8443 &&
                    ipv6Endpoint.exclusionPrefixLength == 128, "incorrect IPv6 candidate")
        for address in ["example.test:443", "203.0.113.1:443-444", "203.0.113.1:443,444",
                        "203.0.113.1:0", "127.0.0.1:443", "198.18.0.1:443", "224.0.0.1:443",
                        "[::1]:443", "[fe80::1%en0]:443", "[::ffff:203.0.113.1]:443"] {
            do {
                _ = try ExperimentalEndpointCandidate(server: address, tlsServerName: "example.test")
                throw ProviderSmokeError.failed("unexpected endpoint accepted: \(address)")
            } catch ExperimentalEndpointError.invalidAddress {}
        }
        do {
            _ = try ExperimentalEndpointCandidate(server: "203.0.113.1:443", tlsServerName: "")
            throw ProviderSmokeError.failed("missing TLS server name accepted")
        } catch ExperimentalEndpointError.invalidAddress {}
        print("numeric single-endpoint candidate and exact prefix validation: OK")

        let system = ManualProviderSystem()
        let factory = ProviderEngineFactory()
        let cleanupErrors = CompletionProbe()
        let provider = coordinator(system: system, factory: factory, cleanupFailures: cleanupErrors)
        let started = CompletionProbe()
        provider.start(configuration: Data("fixture".utf8), completion: started.receive)
        try waitFor("engine created") { factory.count() == 1 && factory.engine(0).counts().0 == 1 }
        let engine = factory.engine(0)
        engine.completeStart(.success(()))
        try waitFor("settings install") { system.counts().0 == 1 }
        try require(engine.counts().1 == 0 && started.count() == 0, "attached before settings")
        system.completeInstall(0, .success(()))
        try waitFor("packet flow attach") { engine.counts().1 == 1 }
        engine.completeAttach(.success(()))
        try started.wait().get()
        let stopped = CompletionProbe()
        provider.stop(completion: stopped.receive)
        try waitFor("stop and clear requested") { engine.counts().2 == 1 && system.counts().1 == 1 }
        engine.completeStop(0, .success(()))
        usleep(30_000)
        try require(stopped.count() == 0, "stop completed before settings clear")
        system.completeClear(0, .success(()))
        try stopped.wait().get()
        try require(started.count() == 1 && stopped.count() == 1, "completion repeated")
        print("start -> settings -> attach and complete cleanup: OK")

        let lateSystem = ManualProviderSystem()
        let lateFactory = ProviderEngineFactory()
        let lateErrors = CompletionProbe()
        let lateProvider = coordinator(system: lateSystem, factory: lateFactory, cleanupFailures: lateErrors)
        let lateStart = CompletionProbe()
        lateProvider.start(configuration: Data(), completion: lateStart.receive)
        try waitFor("late engine created") { lateFactory.count() == 1 && lateFactory.engine(0).counts().0 == 1 }
        let lateEngine = lateFactory.engine(0)
        lateEngine.completeStart(.success(()))
        try waitFor("late settings install") { lateSystem.counts().0 == 1 }
        let lateStop = CompletionProbe()
        lateProvider.stop(completion: lateStop.receive)
        try expectProviderError(try lateStart.wait(), .cancelled)
        try waitFor("late engine stop") { lateEngine.counts().2 == 1 }
        lateEngine.completeStop(0, .success(()))
        usleep(40_000)
        try require(lateSystem.counts().1 == 0 && lateStop.count() == 0, "clear raced outstanding install")
        lateSystem.completeInstall(0, .success(()))
        try waitFor("late settings clear") { lateSystem.counts().1 == 1 }
        lateSystem.completeClear(0, .success(()))
        try lateStop.wait().get()
        lateSystem.completeInstall(0, .success(()))
        usleep(30_000)
        try require(lateEngine.counts().1 == 0 && lateStart.count() == 1 && lateStop.count() == 1,
                    "late install attached or repeated completion")
        print("stop during settings install waits before clearing: OK")

        let earlySystem = ManualProviderSystem()
        let earlyFactory = ProviderEngineFactory()
        let earlyErrors = CompletionProbe()
        let earlyProvider = coordinator(system: earlySystem, factory: earlyFactory, cleanupFailures: earlyErrors)
        let earlyStart = CompletionProbe()
        earlyProvider.start(configuration: Data(), completion: earlyStart.receive)
        try waitFor("early engine start") { earlyFactory.count() == 1 && earlyFactory.engine(0).counts().0 == 1 }
        let earlyEngine = earlyFactory.engine(0)
        let earlyStop = CompletionProbe()
        let concurrentStop = CompletionProbe()
        earlyProvider.stop(completion: earlyStop.receive)
        earlyProvider.stop(completion: concurrentStop.receive)
        try expectProviderError(try earlyStart.wait(), .cancelled)
        try waitFor("early engine stop") { earlyEngine.counts().2 == 1 }
        earlyEngine.completeStart(.success(()))
        earlyEngine.completeStop(0, .success(()))
        try earlyStop.wait().get()
        try concurrentStop.wait().get()
        try require(earlySystem.counts().0 == 0 && earlySystem.counts().1 == 0 && earlyStart.count() == 1,
                    "late startup installed settings after stop")
        print("stop during core startup ignores late success and joins concurrent stops: OK")

        let attachSystem = ManualProviderSystem()
        let attachFactory = ProviderEngineFactory()
        let attachErrors = CompletionProbe()
        let attachProvider = coordinator(system: attachSystem, factory: attachFactory, cleanupFailures: attachErrors)
        let attachStart = CompletionProbe()
        attachProvider.start(configuration: Data(), completion: attachStart.receive)
        try waitFor("attach engine") { attachFactory.count() == 1 && attachFactory.engine(0).counts().0 == 1 }
        let attachEngine = attachFactory.engine(0)
        attachEngine.completeStart(.success(()))
        try waitFor("attach install") { attachSystem.counts().0 == 1 }
        attachSystem.completeInstall(0, .success(()))
        try waitFor("attach pending") { attachEngine.counts().1 == 1 }
        let attachStop = CompletionProbe()
        attachProvider.stop(completion: attachStop.receive)
        try expectProviderError(try attachStart.wait(), .cancelled)
        try waitFor("attach cleanup") { attachEngine.counts().2 == 1 && attachSystem.counts().1 == 1 }
        attachEngine.completeStop(0, .success(()))
        attachSystem.completeClear(0, .success(()))
        try attachStop.wait().get()
        attachEngine.completeAttach(.success(()))
        usleep(30_000)
        try require(attachStart.count() == 1 && attachStop.count() == 1, "late attach repeated completion")
        print("stop during attach ignores late attach success: OK")

        let blockedSystem = ManualProviderSystem()
        let blockedFactory = ProviderEngineFactory()
        let blockedErrors = CompletionProbe()
        let blockedProvider = coordinator(system: blockedSystem, factory: blockedFactory, cleanupFailures: blockedErrors)
        let blockedStart = CompletionProbe()
        blockedProvider.start(configuration: Data(), completion: blockedStart.receive)
        try waitFor("blocked engine created") { blockedFactory.count() == 1 && blockedFactory.engine(0).counts().0 == 1 }
        let blockedEngine = blockedFactory.engine(0)
        blockedEngine.completeStart(.success(()))
        try waitFor("blocked install") { blockedSystem.counts().0 == 1 }
        blockedSystem.completeInstall(0, .failure(ProviderSmokeError.fixture))
        guard case .failure = try blockedStart.wait() else { throw ProviderSmokeError.failed("install failure was lost") }
        try waitFor("rollback started") { blockedEngine.counts().2 == 1 && blockedSystem.counts().1 == 1 }
        blockedEngine.completeStop(0, .success(()))
        blockedSystem.completeClear(0, .failure(ProviderSmokeError.fixture))
        guard case .failure = try blockedErrors.wait() else { throw ProviderSmokeError.failed("cleanup failure missing") }
        let refused = CompletionProbe()
        blockedProvider.start(configuration: Data(), completion: refused.receive)
        try expectProviderError(try refused.wait(), .cleanupIncomplete)
        let retry = CompletionProbe()
        blockedProvider.stop(completion: retry.receive)
        try waitFor("retry clear") { blockedSystem.counts().1 == 2 }
        try require(blockedEngine.counts().2 == 1, "already stopped engine was stopped again")
        blockedSystem.completeClear(0, .success(()))
        usleep(30_000)
        try require(retry.count() == 0, "old cleanup callback completed a new retry")
        blockedSystem.completeClear(1, .success(()))
        try retry.wait().get()
        let restartedStart = CompletionProbe()
        blockedProvider.start(configuration: Data(), completion: restartedStart.receive)
        try waitFor("restart after recovery") { blockedFactory.count() == 2 && blockedFactory.engine(1).counts().0 == 1 }
        let restartedStop = CompletionProbe()
        blockedProvider.stop(completion: restartedStop.receive)
        try expectProviderError(try restartedStart.wait(), .cancelled)
        try waitFor("restart engine stop") { blockedFactory.engine(1).counts().2 == 1 }
        blockedFactory.engine(1).completeStop(0, .success(()))
        try restartedStop.wait().get()
        print("failed settings rollback blocks restart until explicit successful retry: OK")

        let runtimeSystem = ManualProviderSystem()
        let runtimeFactory = ProviderEngineFactory()
        let runtimeErrors = CompletionProbe()
        let runtimeProvider = coordinator(system: runtimeSystem, factory: runtimeFactory, cleanupFailures: runtimeErrors)
        let runtimeStart = CompletionProbe()
        runtimeProvider.start(configuration: Data(), completion: runtimeStart.receive)
        try waitFor("runtime engine") { runtimeFactory.count() == 1 && runtimeFactory.engine(0).counts().0 == 1 }
        let runtimeEngine = runtimeFactory.engine(0)
        runtimeEngine.completeStart(.success(()))
        try waitFor("runtime install") { runtimeSystem.counts().0 == 1 }
        runtimeSystem.completeInstall(0, .success(()))
        try waitFor("runtime attach") { runtimeEngine.counts().1 == 1 }
        runtimeEngine.completeAttach(.success(()))
        try runtimeStart.wait().get()
        runtimeEngine.failure(ProviderSmokeError.fixture)
        try waitFor("runtime cancellation") { runtimeSystem.counts().2 == 1 && runtimeEngine.counts().2 == 1 && runtimeSystem.counts().1 == 1 }
        let runtimeStop = CompletionProbe()
        runtimeProvider.stop(completion: runtimeStop.receive)
        runtimeEngine.completeStop(0, .success(()))
        runtimeSystem.completeClear(0, .success(()))
        try runtimeStop.wait().get()
        try require(runtimeSystem.counts().2 == 1 && runtimeStart.count() == 1, "runtime failure was reported repeatedly")
        print("running engine failure cancels tunnel and shares cleanup with stop: OK")

        let engineSystem = ManualProviderSystem()
        let engineFactory = ProviderEngineFactory()
        let engineErrors = CompletionProbe()
        let engineProvider = coordinator(system: engineSystem, factory: engineFactory, cleanupFailures: engineErrors)
        let engineStart = CompletionProbe()
        engineProvider.start(configuration: Data(), completion: engineStart.receive)
        try waitFor("engine retry start") { engineFactory.count() == 1 && engineFactory.engine(0).counts().0 == 1 }
        let retryEngine = engineFactory.engine(0)
        retryEngine.completeStart(.success(()))
        try waitFor("engine retry install") { engineSystem.counts().0 == 1 }
        engineSystem.completeInstall(0, .success(()))
        try waitFor("engine retry attach") { retryEngine.counts().1 == 1 }
        retryEngine.completeAttach(.success(()))
        try engineStart.wait().get()
        let badStop = CompletionProbe()
        engineProvider.stop(completion: badStop.receive)
        try waitFor("engine retry cleanup") { retryEngine.counts().2 == 1 && engineSystem.counts().1 == 1 }
        retryEngine.completeStop(0, .failure(ProviderSmokeError.fixture))
        engineSystem.completeClear(0, .success(()))
        guard case .failure = try badStop.wait() else { throw ProviderSmokeError.failed("engine stop failure missing") }
        let engineRefused = CompletionProbe()
        engineProvider.start(configuration: Data(), completion: engineRefused.receive)
        try expectProviderError(try engineRefused.wait(), .cleanupIncomplete)
        let engineRetry = CompletionProbe()
        engineProvider.stop(completion: engineRetry.receive)
        try waitFor("retry engine stop") { retryEngine.counts().2 == 2 }
        try require(engineSystem.counts().1 == 1, "already-cleared settings were cleared again")
        retryEngine.completeStop(1, .success(()))
        try engineRetry.wait().get()
        print("failed engine stop blocks restart until successful retry: OK")
    }
}
