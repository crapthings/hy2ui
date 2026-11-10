import Foundation
import Testing
@testable import Hy2Models

/// Confirms an already-cancelled request never submits work or waits for authorization.
@Test @MainActor func cancelledRequestDoesNotSubmit() async {
    let request = CancellableRequest()
    var submitted = false
    let task = Task { try await request.wait(id: UUID()) { _ in submitted = true } }
    task.cancel()
    do { try await task.value; Issue.record("A cancelled request unexpectedly completed") }
    catch { #expect(error is CancellationError) }
    #expect(!submitted)
}

/// Confirms late completion from a cancelled request cannot resume its replacement.
@Test @MainActor func staleRequestCompletionIsIgnored() async throws {
    let request = CancellableRequest()
    let firstID = UUID()
    var submitted = false
    let first = Task { try await request.wait(id: firstID) { _ in submitted = true } }
    defer { first.cancel() }
    try await waitUntil { submitted }
    first.cancel()
    do { try await first.value; Issue.record("Cancellation was ignored") }
    catch { #expect(error is CancellationError) }
    let secondID = UUID()
    submitted = false
    let second = Task { try await request.wait(id: secondID) { _ in submitted = true } }
    defer { second.cancel() }
    try await waitUntil { submitted }
    #expect(!request.complete(id: firstID, result: .success(())))
    #expect(request.complete(id: secondID, result: .success(())))
    try await second.value
    #expect(!request.complete(id: secondID, result: .success(())))
}

/// Confirms session replacement and stop deliver cancellation exactly once.
@Test func sessionStopRejectsStaleStartupSuccess() {
    var sessions = SessionGeneration<Void>()
    var firstResults: [Bool] = []
    var secondResults: [Bool] = []
    let first = sessions.begin { firstResults.append((try? $0.get()) != nil) }
    let second = sessions.begin { secondResults.append((try? $0.get()) != nil) }
    #expect(firstResults == [false])
    let oldFinished = sessions.finish(first, result: .success(()))
    #expect(!oldFinished)
    sessions.invalidate()
    sessions.invalidate()
    #expect(secondResults == [false])
    #expect(!sessions.contains(second))
    let cancelledFinished = sessions.finish(second, result: .success(()))
    #expect(!cancelledFinished)
}

/// Confirms successful startup does not receive a second completion when stopped.
@Test func successfulSessionCompletesOnlyOnce() {
    var sessions = SessionGeneration<Void>()
    var completions = 0
    let token = sessions.begin { _ in completions += 1 }
    let finished = sessions.finish(token, result: .success(()))
    #expect(finished)
    #expect(sessions.contains(token))
    let finishedAgain = sessions.finish(token, result: .success(()))
    #expect(!finishedAgain)
    sessions.invalidate()
    #expect(completions == 1)
}

/// Waits briefly for an actor-scheduled test request without assuming a fixed scheduling order.
@MainActor private func waitUntil(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while !predicate() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
    try #require(predicate(), "Request was not submitted before the test deadline")
}
