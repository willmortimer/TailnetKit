import Foundation

/// In-process tailnet backend for tests and previews when Go TailnetCore is not linked.
public actor InMemoryTailnetBackend: TailnetBackend {
    public nonisolated let kind: TailnetBackendKind = .developmentStub

    private var running = false
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

    public func configure(profile: TailnetProfile, stateDirectory: URL) async throws {}

    public func start() async throws {
        running = true
        eventsContinuation.yield(.state(.running(ipv4: "100.64.0.2", ipv6: nil)))
    }

    public func stop() async {
        running = false
        eventsContinuation.yield(.state(.stopped))
    }

    public func currentState() async -> TailnetState {
        running ? .running(ipv4: "100.64.0.2", ipv6: nil) : .stopped
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

private final class InMemoryTailnetConnection: TailnetConnection, @unchecked Sendable {
    private let host: String
    private let port: Int
    private var closed = false

    init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    func read(maxBytes: Int) async throws -> Data {
        try await Task.sleep(nanoseconds: 50_000_000)
        return Data()
    }

    func write(_ data: Data) async throws {
        if closed { throw TailnetError.dialFailed("connection closed") }
    }

    func close() async {
        closed = true
    }
}
