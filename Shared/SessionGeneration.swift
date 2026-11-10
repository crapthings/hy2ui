import Foundation

/// Delivers each session's startup result once and rejects work from superseded sessions.
public struct SessionGeneration<Value> {
    private var token: UUID?
    private var completion: ((Result<Value, Error>) -> Void)?

    public init() {}

    public mutating func begin(completion: @escaping (Result<Value, Error>) -> Void) -> UUID {
        invalidate()
        let token = UUID()
        self.token = token
        self.completion = completion
        return token
    }

    public func contains(_ token: UUID) -> Bool { self.token == token }

    @discardableResult
    public mutating func finish(_ token: UUID, result: Result<Value, Error>) -> Bool {
        guard self.token == token, let completion else { return false }
        self.completion = nil
        completion(result)
        return true
    }

    public mutating func invalidate() {
        token = nil
        let completion = self.completion
        self.completion = nil
        completion?(.failure(CancellationError()))
    }
}
