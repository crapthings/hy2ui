import Foundation

/// Serializes provider startup, settings installation, cancellation and cleanup across one session.
final class ExperimentalProviderCoordinator: @unchecked Sendable {
    private enum Phase { case starting, installing, attaching, running, stopping, cleanupBlocked }

    private final class Session {
        let token: UUID
        let engine: ExperimentalProviderEngine
        var phase = Phase.starting
        var startCompletion: ((Result<Void, Error>) -> Void)?
        var stopCompletions: [(Result<Void, Error>) -> Void] = []
        var installing = false
        var settingsCleared = true
        var engineStopped = false
        var engineAttempted = false
        var clearAttempted = false
        var engineInFlight = false
        var clearInFlight = false
        var cleanupError: Error?
        var cleanupRound: UInt64 = 0

        init(token: UUID, engine: ExperimentalProviderEngine, completion: @escaping (Result<Void, Error>) -> Void) {
            self.token = token
            self.engine = engine
            self.startCompletion = completion
        }
    }

    private let queue = DispatchQueue(label: "dev.hy2ui.experimental-provider-coordinator")
    private let callbackQueue: DispatchQueue
    private let system: ExperimentalProviderSystem
    private let engineFactory: (@escaping (Error) -> Void) -> ExperimentalProviderEngine
    private let onCleanupFailure: (Error) -> Void
    private var session: Session?

    init(system: ExperimentalProviderSystem, callbackQueue: DispatchQueue,
         engineFactory: @escaping (@escaping (Error) -> Void) -> ExperimentalProviderEngine,
         onCleanupFailure: @escaping (Error) -> Void) {
        self.system = system
        self.callbackQueue = callbackQueue
        self.engineFactory = engineFactory
        self.onCleanupFailure = onCleanupFailure
    }

    func start(configuration: Data, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            if let current = self.session {
                let error: ExperimentalProviderError = current.phase == .cleanupBlocked ? .cleanupIncomplete : .busy
                self.deliver { completion(.failure(error)) }
                return
            }
            let token = UUID()
            let engine = self.engineFactory { [weak self] error in
                guard let self else { return }
                self.queue.async { [weak self] in
                    guard let self else { return }
                    self.engineFailed(token, error: error)
                }
            }
            let current = Session(token: token, engine: engine, completion: completion)
            self.session = current
            engine.start(configuration: configuration) { [weak self] result in
                guard let self else { return }
                self.queue.async { [weak self] in self?.engineStarted(current.token, result: result) }
            }
        }
    }

    func stop(completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            guard let current = self.session else {
                self.deliver { completion(.success(())) }
                return
            }
            current.stopCompletions.append(completion)
            switch current.phase {
            case .stopping:
                return
            case .cleanupBlocked:
                current.phase = .stopping
                current.cleanupError = nil
                current.engineAttempted = false
                current.clearAttempted = false
                current.cleanupRound &+= 1
                self.progressCleanup(current)
            default:
                self.beginCleanup(current, startError: ExperimentalProviderError.cancelled)
            }
        }
    }

    private func engineStarted(_ token: UUID, result: Result<Void, Error>) {
        guard let current = matching(token), current.phase == .starting else { return }
        switch result {
        case let .failure(error):
            beginCleanup(current, startError: error)
        case .success:
            current.phase = .installing
            current.installing = true
            current.settingsCleared = false
            system.installSettings { [weak self] result in
                guard let self else { return }
                self.queue.async { [weak self] in self?.settingsInstalled(token, result: result) }
            }
        }
    }

    private func settingsInstalled(_ token: UUID, result: Result<Void, Error>) {
        guard let current = matching(token), current.installing else { return }
        current.installing = false
        if current.phase == .stopping {
            progressCleanup(current)
            return
        }
        guard current.phase == .installing else { return }
        switch result {
        case let .failure(error):
            beginCleanup(current, startError: error)
        case .success:
            current.phase = .attaching
            current.engine.attach(flow: system.packetFlow) { [weak self] result in
                guard let self else { return }
                self.queue.async { [weak self] in self?.engineAttached(token, result: result) }
            }
        }
    }

    private func engineAttached(_ token: UUID, result: Result<Void, Error>) {
        guard let current = matching(token), current.phase == .attaching else { return }
        switch result {
        case let .failure(error):
            beginCleanup(current, startError: error)
        case .success:
            current.phase = .running
            finishStart(current, result: .success(()))
        }
    }

    private func engineFailed(_ token: UUID, error: Error) {
        guard let current = matching(token), current.phase != .stopping, current.phase != .cleanupBlocked else { return }
        if current.phase == .running { system.cancelTunnel(error: error) }
        beginCleanup(current, startError: error)
    }

    private func beginCleanup(_ current: Session, startError: Error) {
        current.phase = .stopping
        finishStart(current, result: .failure(startError))
        current.cleanupError = nil
        current.engineAttempted = false
        current.clearAttempted = false
        current.cleanupRound &+= 1
        progressCleanup(current)
    }

    private func progressCleanup(_ current: Session) {
        guard matching(current.token) === current, current.phase == .stopping else { return }
        if !current.engineStopped && !current.engineAttempted {
            current.engineAttempted = true
            current.engineInFlight = true
            let round = current.cleanupRound
            current.engine.stop { [weak self] result in
                guard let self else { return }
                self.queue.async { [weak self] in self?.engineStopped(current.token, round: round, result: result) }
            }
        }
        // An outstanding install can apply after stop, so clear only after it completes.
        if !current.settingsCleared && !current.installing && !current.clearAttempted {
            current.clearAttempted = true
            current.clearInFlight = true
            let round = current.cleanupRound
            system.clearSettings { [weak self] result in
                guard let self else { return }
                self.queue.async { [weak self] in self?.settingsCleared(current.token, round: round, result: result) }
            }
        }
        guard !current.installing, !current.engineInFlight, !current.clearInFlight else { return }
        guard current.engineStopped || current.engineAttempted else { return }
        guard current.settingsCleared || current.clearAttempted else { return }
        let completions = current.stopCompletions
        current.stopCompletions = []
        if current.engineStopped && current.settingsCleared {
            session = nil
            for completion in completions { deliver { completion(.success(())) } }
        } else {
            current.phase = .cleanupBlocked
            let error = current.cleanupError ?? ExperimentalProviderError.cleanupIncomplete
            for completion in completions { deliver { completion(.failure(error)) } }
            if completions.isEmpty { deliver { self.onCleanupFailure(error) } }
        }
    }

    private func engineStopped(_ token: UUID, round: UInt64, result: Result<Void, Error>) {
        guard let current = matching(token), current.phase == .stopping, current.engineInFlight,
              current.cleanupRound == round else { return }
        current.engineInFlight = false
        switch result {
        case .success: current.engineStopped = true
        case let .failure(error): current.cleanupError = current.cleanupError ?? error
        }
        progressCleanup(current)
    }

    private func settingsCleared(_ token: UUID, round: UInt64, result: Result<Void, Error>) {
        guard let current = matching(token), current.phase == .stopping, current.clearInFlight,
              current.cleanupRound == round else { return }
        current.clearInFlight = false
        switch result {
        case .success: current.settingsCleared = true
        case let .failure(error): current.cleanupError = current.cleanupError ?? error
        }
        progressCleanup(current)
    }

    private func finishStart(_ current: Session, result: Result<Void, Error>) {
        let completion = current.startCompletion
        current.startCompletion = nil
        if let completion { deliver { completion(result) } }
    }

    private func matching(_ token: UUID) -> Session? {
        guard let session, session.token == token else { return nil }
        return session
    }

    private func deliver(_ callback: @escaping () -> Void) {
        callbackQueue.async(execute: callback)
    }
}
