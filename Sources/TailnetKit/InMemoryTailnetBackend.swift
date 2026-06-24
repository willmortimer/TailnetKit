import Foundation

/// In-process tailnet backend for tests and simulator when Go TailnetCore is not linked.
public actor InMemoryTailnetBackend: TailnetBackend {
    public nonisolated let kind: TailnetBackendKind = .developmentStub

    private var running = false
    private var peersList: [TailnetPeer] = []
    private let eventsContinuation: AsyncStream<TailnetEvent>.Continuation
    public var events: AsyncStream<TailnetEvent> {
        eventsStream
    }

    private let eventsStream: AsyncStream<TailnetEvent>

    public init(peers: [TailnetPeer] = []) {
        self.peersList = peers
        var continuation: AsyncStream<TailnetEvent>.Continuation!
        self.eventsStream = AsyncStream { cont in
            continuation = cont
        }
        self.eventsContinuation = continuation
    }

    public func start(profile: TailnetProfile, stateDirectory: URL) async throws {
        _ = stateDirectory
        running = true
        eventsContinuation.yield(.state(.running(ipv4: "100.64.0.2", ipv6: nil)))
    }

    public func stop(profileID: UUID) async {
        _ = profileID
        running = false
        eventsContinuation.yield(.state(.stopped))
    }

    public func state(profileID: UUID) async -> TailnetState {
        _ = profileID
        return running ? .running(ipv4: "100.64.0.2", ipv6: nil) : .stopped
    }

    public func peers(profileID: UUID) async throws -> [TailnetPeer] {
        _ = profileID
        guard running else { throw TailnetError.notRunning }
        return peersList
    }

    public func dialTCP(profileID: UUID, host: String, port: Int) async throws -> any TailnetConnection {
        _ = profileID
        guard running else { throw TailnetError.notRunning }
        return InMemoryTailnetConnection(host: host, port: port)
    }
}

private final class InMemoryTailnetConnection: TailnetConnection, @unchecked Sendable {
    private let host: String
    private let port: Int
    private var closed = false

    init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    func read(maxBytes: Int) async throws -> Data {
        _ = maxBytes
        try await Task.sleep(nanoseconds: 50_000_000)
        return Data()
    }

    func write(_ data: Data) async throws {
        _ = data
        if closed { throw TailnetError.dialFailed("connection closed") }
    }

    func close() async {
        closed = true
    }
}
