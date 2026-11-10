import Foundation
import Network

/// Measures bounded TCP connection setup time without credentials or system network changes.
enum ServerLatencyProbe {
    static func measure(host: String, port: Int) async -> Int? {
        guard !host.isEmpty, (1...65535).contains(port), let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return nil }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let attempt = Attempt(connection: connection, continuation: continuation)
                attempt.start()
            }
        } onCancel: { connection.cancel() }
    }

    /// Serializes timeout and connection callbacks so each measurement completes exactly once.
    private final class Attempt: @unchecked Sendable {
        private let queue = DispatchQueue(label: "dev.hy2ui.latency")
        private let connection: NWConnection
        private var continuation: CheckedContinuation<Int?, Never>?
        private let startTime = DispatchTime.now().uptimeNanoseconds
        private var timeout: DispatchWorkItem?

        init(connection: NWConnection, continuation: CheckedContinuation<Int?, Never>) {
            self.connection = connection
            self.continuation = continuation
        }

        func start() {
            connection.stateUpdateHandler = { [self] state in
                switch state {
                case .ready: finish(max(1, Int((DispatchTime.now().uptimeNanoseconds - startTime) / 1_000_000)))
                case .failed, .cancelled: finish(nil)
                default: break
                }
            }
            let timeout = DispatchWorkItem { [self] in finish(nil) }
            self.timeout = timeout
            queue.asyncAfter(deadline: .now() + 3, execute: timeout)
            connection.start(queue: queue)
        }

        private func finish(_ value: Int?) {
            guard let continuation else { return }
            self.continuation = nil
            timeout?.cancel()
            timeout = nil
            connection.stateUpdateHandler = nil
            connection.cancel()
            continuation.resume(returning: value)
        }
    }
}
