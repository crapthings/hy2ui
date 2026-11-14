import Foundation
import SystemExtensions

/// Serializes explicit activation requests and completes each waiter once, including cancellation.
final class SystemExtensionActivator: NSObject, OSSystemExtensionRequestDelegate {
    private var pending: (OSSystemExtensionRequest, CheckedContinuation<Void, Error>)?
    var onApprovalRequired: (() -> Void)?

    @MainActor
    func activate(identifier: String) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard pending == nil else { continuation.resume(throwing: ProviderActivationError.busy); return }
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: identifier, queue: .main)
                pending = (request, continuation)
                request.delegate = self
                OSSystemExtensionManager.shared.submitRequest(request)
            }
        } onCancel: { DispatchQueue.main.async { self.cancel() } }
    }

    func cancel() {
        let continuation = pending?.1
        pending = nil
        continuation?.resume(throwing: CancellationError())
    }
    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        if pending?.0 === request { onApprovalRequired?() }
    }
    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        finish(request, result: .failure(error))
    }
    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        finish(request, result: result == .completed ? .success(()) : .failure(ProviderActivationError.rebootRequired))
    }
    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension replacement: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction { .replace }

    private func finish(_ request: OSSystemExtensionRequest, result: Result<Void, Error>) {
        guard pending?.0 === request else { return }
        let continuation = pending?.1
        pending = nil
        continuation?.resume(with: result)
    }
}

/// Keeps activation failures independent from credentials and low-level signing logs.
enum ProviderActivationError: Error, LocalizedError {
    case busy, rebootRequired, unavailable, timedOut, captureDisabled, startFailed
    var errorDescription: String? {
        switch self {
        case .busy: "网络扩展操作正在进行。"
        case .rebootRequired: "网络扩展更新需要重启系统后完成。"
        case .unavailable: "无法取得物理网络接口或网络扩展配置。"
        case .timedOut: "网络扩展操作超时，停止状态尚需核对。"
        case .captureDisabled: "当前是离线 Network Extension 构建，接管默认关闭；启用前需要有效 Apple 签名和明确的测试构建开关。"
        case .startFailed: "网络扩展未能启动，请检查扩展签名、接管开关及系统 VPN 错误。"
        }
    }
}
