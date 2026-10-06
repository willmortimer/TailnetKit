import Foundation
import TailnetKitCore

/// In-process tailnet backend for tests and previews when Go TailnetCore is not linked.
public actor InMemoryTailnetBackend: TailnetBackend {
    public nonisolated let kind: TailnetBackendKind = .developmentStub

    private var phase = TailnetRuntimePhase()
    private var peersList: [TailnetPeer]
    private var startSuspension: (@Sendable () async throws -> Void)?
    private var startWaiters: [CheckedContinuation<Void, Error>] = []
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private var startBridgeFinished: CheckedContinuation<Void, Never>?
    private let eventsContinuation: AsyncStream<TailnetEvent>.Continuation
    private let eventsStream: AsyncStream<TailnetEvent>

    public nonisolated var events: AsyncStream<TailnetEvent> { eventsStream }

    public init(peers: [TailnetPeer] = []) {
        self.peersList = peers
        var continuation: AsyncStream<TailnetEvent>.Continuation!
        self.eventsStream = AsyncStream { cont in continuation = cont }
        self.eventsContinuation = continuation
    }

    private var stubIdentity: TailnetIdentity {
        TailnetIdentity(hostname: phase.profile?.hostname ?? "stub", ipv4: "100.64.0.2")
    }

    /// Runs after the phase enters `.starting` and before it becomes `.running`.
    /// Tests use this to reenter `configure` during start.
    public func setStartSuspension(_ suspension: (@Sendable () async throws -> Void)?) {
        startSuspension = suspension
    }

    public func configure(profile: TailnetProfile, stateDirectory: URL) async throws {
        _ = stateDirectory
        try phase.configure(profile)
    }

    public func start() async throws {
        switch try phase.beginStart() {
        case .alreadyRunning:
            return
        case .joinInFlight:
            try await withCheckedThrowingContinuation { startWaiters.append($0) }
        case .afterStop:
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                stopWaiters.append(continuation)
            }
            try await start()
        case .start(let profile):
            do {
                if let startSuspension {
                    try await startSuspension()
                }
            } catch {
                phase.failStart(profileID: profile.id)
                startBridgeFinished?.resume()
                startBridgeFinished = nil
                resumeStartWaiters(.failure(error))
                throw error
            }
            if !phase.finishStart(profileID: profile.id) {
                startBridgeFinished?.resume()
                startBridgeFinished = nil
            } else {
                eventsContinuation.yield(.state(.running(stubIdentity)))
            }
            resumeStartWaiters(.success(()))
        }
    }

    public func stop() async {
        switch phase.beginStop() {
        case .none:
            return
        case .joinInFlight:
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                stopWaiters.append(continuation)
            }
        case .stop(let profile, let interruptedStart):
            if interruptedStart {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    startBridgeFinished = continuation
                }
            }
            phase.finishStop(profileID: profile.id)
            eventsContinuation.yield(.state(.stopped))
            let waiters = stopWaiters
            stopWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    public func currentState() async -> TailnetState {
        phase.isRunning ? .running(stubIdentity) : .stopped
    }

    public func peers() async throws -> [TailnetPeer] {
        guard phase.isRunning else { throw TailnetError.notRunning }
        return peersList
    }

    public func dialTCP(host: String, port: Int) async throws -> any TailnetConnection {
        guard phase.isRunning else { throw TailnetError.notRunning }
        return InMemoryTailnetConnection(host: host, port: port)
    }

    private func resumeStartWaiters(_ result: Result<Void, Error>) {
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            switch result {
            case .success:
                waiter.resume()
            case .failure(let error):
                waiter.resume(throwing: error)
            }
        }
    }
}

private final class ReadSlot: @unchecked Sendable {
    enum State {
        case idle
        case armed
        case finished
        case earlyCancel
    }

    var state: State = .idle
}

private final class InMemoryTailnetConnection: TailnetConnection, @unchecked Sendable {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Data, Error>
    }

    private let lock = NSLock()
    private var closed = false
    private var waiters: [Waiter] = []

    init(host: String, port: Int) {
        _ = host
        _ = port
    }

    /// Suspends until close. An empty payload is clean EOF, matching `TailnetConnection`.
    func read(maxBytes: Int) async throws -> Data {
        let id = UUID()
        let slot = ReadSlot()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if slot.state == .earlyCancel {
                    slot.state = .finished
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if closed {
                    slot.state = .finished
                    lock.unlock()
                    continuation.resume(returning: Data())
                    return
                }
                waiters.append(Waiter(id: id, continuation: continuation))
                slot.state = .armed
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            if let index = waiters.firstIndex(where: { $0.id == id }) {
                let waiter = waiters.remove(at: index)
                slot.state = .finished
                lock.unlock()
                waiter.continuation.resume(throwing: CancellationError())
                return
            }
            if slot.state == .idle {
                slot.state = .earlyCancel
            }
            lock.unlock()
        }
    }

    func write(_ data: Data) async throws {
        lock.lock()
        let isClosed = closed
        lock.unlock()
        if isClosed { throw TailnetError.destinationUnreachable("connection closed") }
        _ = data
    }

    func finishWriting() async throws {
        throw TailnetError.halfCloseUnsupported
    }

    func close() async {
        lock.lock()
        closed = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in pending {
            waiter.continuation.resume(returning: Data())
        }
    }
}
