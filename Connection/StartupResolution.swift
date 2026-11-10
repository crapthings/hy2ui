import Foundation

/// Lets startup cancellation complete without waiting for a blocking server resolver to return.
@MainActor
final class StartupResolution {
    private var continuation: CheckedContinuation<Data, Error>?
    private var operation: Task<Void, Never>?

    func resolve(_ configuration: Data, using resolver: @escaping @Sendable (Data) async throws -> Data) async throws -> Data {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                if Task.isCancelled { finish(.failure(CancellationError())); return }
                operation = Task { [weak self] in
                    do { self?.finish(.success(try await resolver(configuration))) }
                    catch { self?.finish(.failure(error)) }
                }
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }

    private func finish(_ result: Result<Data, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        operation?.cancel()
        operation = nil
        continuation.resume(with: result)
    }
}
