import Foundation
import Network

/// Observes the underlying physical path once and never chooses a tunnel interface as fallback.
final class PhysicalInterfaceResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: CheckedContinuation<String, Error>?
    private let monitor = NWPathMonitor()

    func resolve() async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock(); completion = continuation; lock.unlock()
                if Task.isCancelled { finish(.failure(CancellationError())); return }
                monitor.pathUpdateHandler = { [weak self] path in
                    guard let self else { return }
                    guard path.status == .satisfied,
                          let interface = path.availableInterfaces.first(where: {
                              ($0.type == .wifi || $0.type == .wiredEthernet) && path.usesInterfaceType($0.type)
                          }) else { self.finish(.failure(ProviderActivationError.unavailable)); return }
                    self.finish(.success(interface.name))
                }
                monitor.start(queue: DispatchQueue(label: "dev.hy2ui.ne.bootstrap-path"))
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in self?.finish(.failure(ProviderActivationError.timedOut)) }
            }
        } onCancel: { self.finish(.failure(CancellationError())) }
    }

    private func finish(_ result: Result<String, Error>) {
        lock.lock(); let continuation = completion; completion = nil; lock.unlock()
        guard let continuation else { return }
        monitor.cancel()
        continuation.resume(with: result)
    }
}
