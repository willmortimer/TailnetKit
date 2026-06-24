import Foundation
import TailnetKitCore

/// Defers GoTailnetBackend construction until the first tailnet operation so app launch stays responsive.
public actor LazyGoTailnetBackend: TailnetBackend {
    public nonisolated let kind: TailnetBackendKind = .embedded

    private var goBackend: GoTailnetBackend?
    private var forwardEventsTask: Task<Void, Never>?
    private let eventsContinuation: AsyncStream<TailnetEvent>.Continuation
    private let eventsStream: AsyncStream<TailnetEvent>
    private var pendingProfile: TailnetProfile?
    private var pendingStateDirectory: URL?

    public init() {
        var continuation: AsyncStream<TailnetEvent>.Continuation!
        let stream = AsyncStream<TailnetEvent> { cont in
            continuation = cont
        }
        self.eventsStream = stream
        self.eventsContinuation = continuation
    }

    deinit {
        forwardEventsTask?.cancel()
        eventsContinuation.finish()
    }

    public nonisolated var events: AsyncStream<TailnetEvent> {
        eventsStream
    }

    private func ensureGo() async throws -> GoTailnetBackend {
        if let goBackend {
            return goBackend
        }
        TailnetDebug.post("LazyGo: creating TailnetCore bridge (BridgeNewBridge)…")
        let backend = GoTailnetBackend()
        goBackend = backend
        TailnetDebug.post("LazyGo: TailnetCore bridge ready")
        forwardEventsTask = Task { [eventsContinuation] in
            for await event in backend.events {
                eventsContinuation.yield(event)
            }
        }
        if let pendingProfile, let pendingStateDirectory {
            try await backend.configure(profile: pendingProfile, stateDirectory: pendingStateDirectory)
        }
        return backend
    }

    public func configure(profile: TailnetProfile, stateDirectory: URL) async throws {
        pendingProfile = profile
        pendingStateDirectory = stateDirectory
        if let goBackend {
            try await goBackend.configure(profile: profile, stateDirectory: stateDirectory)
        }
    }

    public func start() async throws {
        TailnetDebug.post("LazyGo: start requested")
        try await ensureGo().start()
        TailnetDebug.post("LazyGo: start returned to Swift")
    }

    public func stop() async {
        await goBackend?.stop()
    }

    public func destroyIdentity() async throws {
        if let goBackend {
            try await goBackend.destroyIdentity()
        } else if let pendingStateDirectory {
            try? FileManager.default.removeItem(at: pendingStateDirectory)
        }
        pendingProfile = nil
        pendingStateDirectory = nil
    }

    public func currentState() async -> TailnetState {
        guard let goBackend else { return .stopped }
        return await goBackend.currentState()
    }

    public func peers() async throws -> [TailnetPeer] {
        try await ensureGo().peers()
    }

    public func dialTCP(host: String, port: Int) async throws -> any TailnetConnection {
        try await ensureGo().dialTCP(host: host, port: port)
    }

    public func openLoopbackRelay(host: String, port: Int) async throws -> Int {
        try await ensureGo().openLoopbackRelay(host: host, port: port)
    }

    public func verifyHostKey(hostname: String, port: Int, fingerprintSHA256: String) async -> Bool {
        guard let goBackend else { return false }
        return await goBackend.verifyHostKey(hostname: hostname, port: port, fingerprintSHA256: fingerprintSHA256)
    }
}
