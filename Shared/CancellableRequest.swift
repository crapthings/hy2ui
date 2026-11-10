import Foundation

/// Suspends one request until its matching completion or task cancellation arrives.
@MainActor
public final class CancellableRequest {
    private var pending: (id: UUID, continuation: CheckedContinuation<Void, Error>)?

    public init() {}

    public func wait(id: UUID, submit: (UUID) -> Void) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard pending == nil else {
                    continuation.resume(throwing: ConfigurationError.invalid("已有操作正在等待完成。"))
                    return
                }
                pending = (id, continuation)
                if Task.isCancelled {
                    complete(id: id, result: .failure(CancellationError()))
                } else {
                    submit(id)
                }
            }
        } onCancel: {
            Task { @MainActor in self.complete(id: id, result: .failure(CancellationError())) }
        }
    }

    @discardableResult
    public func complete(id: UUID, result: Result<Void, Error>) -> Bool {
        guard let request = pending, request.id == id else { return false }
        pending = nil
        request.continuation.resume(with: result)
        return true
    }

    public func cancel() {
        guard let request = pending else { return }
        complete(id: request.id, result: .failure(CancellationError()))
    }
}
