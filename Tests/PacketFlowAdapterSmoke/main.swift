import Foundation
import Darwin

/// Reports an assertion failure in the standalone adapter smoke test.
enum AdapterSmokeFailure: Error { case failed(String) }

/// Checks an invariant without requiring XCTest or an app target.
func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw AdapterSmokeFailure.failed(message) }
}

/// Waits for an asynchronously updated predicate using a bounded deadline.
func waitUntil(_ message: String, _ predicate: () -> Bool) throws {
    let deadline = Date().addingTimeInterval(4)
    while Date() < deadline {
        if predicate() { return }
        usleep(5_000)
    }
    throw AdapterSmokeFailure.failed("timed out: \(message)")
}

/// Awaits one adapter completion without blocking its dedicated callback queue.
func awaitResult(_ start: (@escaping (Result<Void, Error>) -> Void) -> Void) throws {
    let semaphore = DispatchSemaphore(value: 0)
    var received: Result<Void, Error>?
    start { result in received = result; semaphore.signal() }
    try check(semaphore.wait(timeout: .now() + 5) == .success, "completion timed out")
    try received!.get()
}

/// Builds a minimal raw IPv4 packet accepted by the adapter.
func ipv4() -> Data {
    var bytes = [UInt8](repeating: 0, count: 20)
    bytes[0] = 0x45
    bytes[3] = 20
    return Data(bytes)
}

/// Builds a minimal raw IPv6 packet accepted by the adapter.
func ipv6() -> Data {
    var bytes = [UInt8](repeating: 0, count: 40)
    bytes[0] = 0x60
    return Data(bytes)
}

/// Provides a lock-protected core fixture with controllable admission and output.
final class FakePacketCore: ExperimentalPacketCore, @unchecked Sendable {
    private let lock = NSLock()
    private var blocked = false
    private var input: [Data] = []
    private var output: [Data] = []
    private var destroyed = 0
    private var statusReads = 0
    private var snapshot = ExperimentalCoreStatus(stackReady: true, connection: "connected", worker: "running", errorCode: nil)

    func setBlocked(_ value: Bool) { lock.lock(); blocked = value; lock.unlock() }
    func setStatus(_ value: ExperimentalCoreStatus) { lock.lock(); snapshot = value; lock.unlock() }
    func addOutput(_ packets: [Data]) { lock.lock(); output += packets; lock.unlock() }
    func received() -> [Data] { lock.lock(); defer { lock.unlock() }; return input }
    func destroyCount() -> Int { lock.lock(); defer { lock.unlock() }; return destroyed }
    func statusCount() -> Int { lock.lock(); defer { lock.unlock() }; return statusReads }

    func status() throws -> ExperimentalCoreStatus {
        lock.lock(); defer { lock.unlock() }
        statusReads += 1
        return snapshot
    }
    func write(_ packet: Data) throws -> ExperimentalPacketAdmission {
        lock.lock(); defer { lock.unlock() }
        if blocked { return .full }
        input.append(packet)
        return .accepted
    }
    func read() throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return output.isEmpty ? nil : output.removeFirst()
    }
    func shutdown() {}
    func destroy() throws { lock.lock(); destroyed += 1; lock.unlock() }
}

/// Simulates a single outstanding system read and records packets returned to the host.
final class FakePacketFlow: ExperimentalPacketFlow, @unchecked Sendable {
    typealias ReadCallback = ([Data], [Int32]) -> Void
    private let lock = NSLock()
    private var callback: ReadCallback?
    private var readCalls = 0
    private var output: [Data] = []
    private var outputFamilies: [Int32] = []
    private var rejectsOutput = false

    func readPackets(completion: @escaping ReadCallback) {
        lock.lock(); defer { lock.unlock() }
        precondition(callback == nil, "only one system read may be pending")
        readCalls += 1
        callback = completion
    }
    func writePackets(_ packets: [Data], families: [Int32]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if rejectsOutput { return false }
        output += packets
        outputFamilies += families
        return true
    }
    func setRejectsOutput(_ value: Bool) { lock.lock(); rejectsOutput = value; lock.unlock() }
    func reads() -> Int { lock.lock(); defer { lock.unlock() }; return readCalls }
    func written() -> ([Data], [Int32]) { lock.lock(); defer { lock.unlock() }; return (output, outputFamilies) }
    func takeCallback() -> ReadCallback? {
        lock.lock(); defer { lock.unlock() }
        let captured = callback
        callback = nil
        return captured
    }
    func deliver(_ packets: [Data], _ families: [Int32]) throws {
        guard let callback = takeCallback() else { throw AdapterSmokeFailure.failed("missing system read") }
        callback(packets, families)
    }
}

/// Runs lifecycle, backlog, stale callback and output handling checks against fake endpoints.
@main enum PacketFlowAdapterSmoke {
    static func makeAdapter(_ core: FakePacketCore, timeout: Duration = .seconds(2),
                            onFailure: @escaping (Error) -> Void = { _ in }) -> ExperimentalPacketAdapter {
        ExperimentalPacketAdapter(callbackQueue: DispatchQueue(label: "test.callback.\(UUID())"),
                                  startupTimeout: timeout, coreFactory: { _ in core }, onFailure: onFailure)
    }

    static func main() throws {
        let core = FakePacketCore()
        let flow = FakePacketFlow()
        let failures = DispatchSemaphore(value: 0)
        let adapter = makeAdapter(core, onFailure: { _ in failures.signal() })
        try awaitResult { adapter.start(configuration: Data(), completion: $0) }
        try awaitResult { adapter.attach(flow: flow, completion: $0) }
        try waitUntil("first read") { flow.reads() == 1 }
        core.setBlocked(true)
        try flow.deliver([ipv4(), ipv6()], [Int32(AF_INET), Int32(AF_INET6)])
        usleep(80_000)
        try check(core.received().isEmpty && flow.reads() == 1, "backpressure did not pause flow reads")
        core.setBlocked(false)
        try waitUntil("input accepted") { core.received().count == 2 && flow.reads() == 2 }
        try check(core.received() == [ipv4(), ipv6()], "input was duplicated or reordered")
        core.addOutput([ipv4(), ipv6()])
        try waitUntil("output delivered") { flow.written().0.count == 2 }
        try check(flow.written().1 == [Int32(AF_INET), Int32(AF_INET6)], "wrong output families")
        guard let stale = flow.takeCallback() else { throw AdapterSmokeFailure.failed("missing pending callback") }
        try awaitResult { adapter.stop(completion: $0) }
        stale([ipv4()], [Int32(AF_INET)])
        usleep(80_000)
        try check(core.received().count == 2 && core.destroyCount() == 1, "stale callback was accepted")
        try check(failures.wait(timeout: .now() + 0.05) == .timedOut, "stop reported an unexpected failure")
        print("backpressure, packet families, stop and stale callbacks: OK")

        let badCore = FakePacketCore()
        let badFlow = FakePacketFlow()
        let badFailure = DispatchSemaphore(value: 0)
        var observed: ExperimentalPacketError?
        let badAdapter = makeAdapter(badCore, onFailure: { observed = $0 as? ExperimentalPacketError; badFailure.signal() })
        try awaitResult { badAdapter.start(configuration: Data(), completion: $0) }
        try awaitResult { badAdapter.attach(flow: badFlow, completion: $0) }
        try waitUntil("invalid-family read") { badFlow.reads() == 1 }
        try badFlow.deliver([ipv6()], [Int32(AF_INET)])
        try check(badFailure.wait(timeout: .now() + 4) == .success, "invalid family did not fail")
        try check(observed == .invalidPacket && badCore.destroyCount() == 1, "invalid family cleanup failed")
        print("mismatched IP family fails and cleans up: OK")

        let fullCore = FakePacketCore()
        let fullFlow = FakePacketFlow()
        let fullFailure = DispatchSemaphore(value: 0)
        var fullError: ExperimentalPacketError?
        let fullAdapter = makeAdapter(fullCore, onFailure: { fullError = $0 as? ExperimentalPacketError; fullFailure.signal() })
        try awaitResult { fullAdapter.start(configuration: Data(), completion: $0) }
        try awaitResult { fullAdapter.attach(flow: fullFlow, completion: $0) }
        try waitUntil("oversized batch read") { fullFlow.reads() == 1 }
        try fullFlow.deliver(Array(repeating: ipv4(), count: 257), Array(repeating: Int32(AF_INET), count: 257))
        try check(fullFailure.wait(timeout: .now() + 4) == .success, "oversized batch did not fail")
        try check(fullError == .packetBacklogExceeded && fullCore.destroyCount() == 1, "oversized batch cleanup failed")
        print("bounded callback batches: OK")

        let bytesCore = FakePacketCore()
        let bytesFlow = FakePacketFlow()
        let bytesFailure = DispatchSemaphore(value: 0)
        var bytesError: ExperimentalPacketError?
        let bytesAdapter = makeAdapter(bytesCore, onFailure: { bytesError = $0 as? ExperimentalPacketError; bytesFailure.signal() })
        try awaitResult { bytesAdapter.start(configuration: Data(), completion: $0) }
        try awaitResult { bytesAdapter.attach(flow: bytesFlow, completion: $0) }
        try waitUntil("large batch read") { bytesFlow.reads() == 1 }
        var large = [UInt8](repeating: 0, count: 65_535)
        large[0] = 0x60
        try bytesFlow.deliver(Array(repeating: Data(large), count: 17), Array(repeating: Int32(AF_INET6), count: 17))
        try check(bytesFailure.wait(timeout: .now() + 4) == .success, "large byte backlog did not fail")
        try check(bytesError == .packetBacklogExceeded && bytesCore.received().isEmpty && bytesCore.destroyCount() == 1,
                  "large byte backlog cleanup failed")
        print("bounded callback bytes: OK")

        let rejectCore = FakePacketCore()
        let rejectFlow = FakePacketFlow()
        rejectFlow.setRejectsOutput(true)
        let rejectFailure = DispatchSemaphore(value: 0)
        var rejectError: ExperimentalPacketError?
        let rejectAdapter = makeAdapter(rejectCore, onFailure: { rejectError = $0 as? ExperimentalPacketError; rejectFailure.signal() })
        try awaitResult { rejectAdapter.start(configuration: Data(), completion: $0) }
        try awaitResult { rejectAdapter.attach(flow: rejectFlow, completion: $0) }
        rejectCore.addOutput([ipv4()])
        try check(rejectFailure.wait(timeout: .now() + 4) == .success, "rejected output did not fail")
        try check(rejectError == .outputRejected && rejectCore.destroyCount() == 1, "rejected output cleanup failed")
        print("system output failure: OK")

        let runningCore = FakePacketCore()
        let runningFlow = FakePacketFlow()
        let runningFailure = DispatchSemaphore(value: 0)
        var runningError: ExperimentalPacketError?
        let runningAdapter = makeAdapter(runningCore, onFailure: { runningError = $0 as? ExperimentalPacketError; runningFailure.signal() })
        try awaitResult { runningAdapter.start(configuration: Data(), completion: $0) }
        try awaitResult { runningAdapter.attach(flow: runningFlow, completion: $0) }
        runningCore.setStatus(ExperimentalCoreStatus(stackReady: false, connection: "closed", worker: "failed", errorCode: "runtime_failure"))
        try check(runningFailure.wait(timeout: .now() + 4) == .success, "running core failure was not observed")
        try check(runningError == .coreFailed("runtime_failure") && runningCore.destroyCount() == 1,
                  "running core failure cleanup failed")
        print("core runtime failure is reported: OK")

        let waitingCore = FakePacketCore()
        waitingCore.setStatus(ExperimentalCoreStatus(stackReady: false, connection: "connecting", worker: "running", errorCode: nil))
        let waitingAdapter = makeAdapter(waitingCore)
        let cancelled = DispatchSemaphore(value: 0)
        var cancelledError: ExperimentalPacketError?
        waitingAdapter.start(configuration: Data()) { result in
            if case let .failure(error) = result { cancelledError = error as? ExperimentalPacketError }
            cancelled.signal()
        }
        try waitUntil("startup observation") { waitingCore.statusCount() > 0 }
        try awaitResult { waitingAdapter.stop(completion: $0) }
        try check(cancelled.wait(timeout: .now() + 4) == .success, "startup cancellation missing")
        try check(cancelledError == .cancelled && waitingCore.destroyCount() == 1, "startup cancellation cleanup failed")
        print("stop while starting: OK")

        let timeoutCore = FakePacketCore()
        timeoutCore.setStatus(ExperimentalCoreStatus(stackReady: false, connection: "connecting", worker: "running", errorCode: nil))
        let timeoutDone = DispatchSemaphore(value: 0)
        var timeoutError: ExperimentalPacketError?
        var timeoutAdapter: ExperimentalPacketAdapter? = makeAdapter(timeoutCore, timeout: .milliseconds(50))
        weak let weakTimeoutAdapter = timeoutAdapter
        timeoutAdapter!.start(configuration: Data()) { result in
            if case let .failure(error) = result { timeoutError = error as? ExperimentalPacketError }
            timeoutDone.signal()
        }
        timeoutAdapter = nil
        try check(timeoutDone.wait(timeout: .now() + 4) == .success, "released startup completion missing")
        try check(timeoutError == .startupTimedOut && timeoutCore.destroyCount() == 1, "startup timeout cleanup failed")
        try waitUntil("adapter deallocation") { weakTimeoutAdapter == nil }
        print("released adapter still completes startup timeout: OK")

        let failedCore = FakePacketCore()
        failedCore.setStatus(ExperimentalCoreStatus(stackReady: false, connection: "closed", worker: "failed", errorCode: "authentication_failed"))
        let failedAdapter = makeAdapter(failedCore)
        let failedDone = DispatchSemaphore(value: 0)
        var startupFailure: ExperimentalPacketError?
        failedAdapter.start(configuration: Data()) { result in
            if case let .failure(error) = result { startupFailure = error as? ExperimentalPacketError }
            failedDone.signal()
        }
        try check(failedDone.wait(timeout: .now() + 4) == .success, "core startup failure missing")
        try check(startupFailure == .coreFailed("authentication_failed") && failedCore.destroyCount() == 1,
                  "core startup error or cleanup incorrect")
        print("core startup failure is reported: OK")

        let firstCore = FakePacketCore()
        let secondCore = FakePacketCore()
        var factoryCount = 0
        let restartFailure = DispatchSemaphore(value: 0)
        let restarted = ExperimentalPacketAdapter(callbackQueue: DispatchQueue(label: "test.restart"),
                                                   coreFactory: { _ in
            factoryCount += 1
            return factoryCount == 1 ? firstCore : secondCore
        }, onFailure: { _ in restartFailure.signal() })
        let firstFlow = FakePacketFlow()
        let secondFlow = FakePacketFlow()
        try awaitResult { restarted.start(configuration: Data(), completion: $0) }
        try awaitResult { restarted.attach(flow: firstFlow, completion: $0) }
        try waitUntil("first session read") { firstFlow.reads() == 1 }
        guard let previousRead = firstFlow.takeCallback() else { throw AdapterSmokeFailure.failed("missing first session read") }
        try awaitResult { restarted.stop(completion: $0) }
        try awaitResult { restarted.start(configuration: Data(), completion: $0) }
        try awaitResult { restarted.attach(flow: secondFlow, completion: $0) }
        try waitUntil("second session read") { secondFlow.reads() == 1 }
        previousRead([ipv4()], [Int32(AF_INET)])
        usleep(50_000)
        try check(secondCore.received().isEmpty && secondFlow.reads() == 1, "old callback reached a new session")
        try secondFlow.deliver([ipv6()], [Int32(AF_INET6)])
        try waitUntil("new session input") { secondCore.received().count == 1 }
        secondCore.addOutput(Array(repeating: ipv4(), count: 130))
        try waitUntil("multiple output batches") { secondFlow.written().0.count == 130 }
        try awaitResult { restarted.stop(completion: $0) }
        try check(firstCore.destroyCount() == 1 && secondCore.destroyCount() == 1, "restart did not release both cores")
        try check(restartFailure.wait(timeout: .now() + 0.05) == .timedOut, "restart reported a failure")
        print("stale callback after restart and multiple output batches: OK")
    }
}
