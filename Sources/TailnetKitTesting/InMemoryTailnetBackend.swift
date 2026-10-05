import Foundation
import TailnetKitCore

/// In-process tailnet backend for tests and previews when Go TailnetCore is not linked.
public actor InMemoryTailnetBackend: TailnetBackend {
    public nonisolated let kind: TailnetBackendKind = .developmentStub

    private var running = false
    private var profile: TailnetProfile?
    private var peersList: [TailnetPeer]
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
        TailnetIdentity(hostname: profile?.hostname ?? "stub", ipv4: "100.64.0.2")
    }

    public func configure(profile: TailnetProfile, stateDirectory: URL) async throws {
        if let current = self.profile, current.id != profile.id, running {
            throw TailnetError.identityAlreadyRunning
        }
        self.profile = profile
    }

    public func start() async throws {
        running = true
        eventsContinuation.yield(.state(.running(stubIdentity)))
    }

    public func stop() async {
        running = false
        eventsContinuation.yield(.state(.stopped))
    }

    public func currentState() async -> TailnetState {
        running ? .running(stubIdentity) : .stopped
    }

    public func peers() async throws -> [TailnetPeer] {
        guard running else { throw TailnetError.notRunning }
        return peersList
    }

    public func dialTCP(host: String, port: Int) async throws -> any TailnetConnection {
        guard running else { throw TailnetError.notRunning }
        return InMemoryTailnetConnection(host: host, port: port)
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
