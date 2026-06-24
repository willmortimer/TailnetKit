import Foundation
import TailnetKit

/// Defers GoTailnetBackend construction until the first tailnet operation so app launch stays responsive.
public actor LazyGoTailnetBackend: TailnetBackend {
    public nonisolated let kind: TailnetBackendKind = .embedded

    private var goBackend: GoTailnetBackend?
    private var forwardEventsTask: Task<Void, Never>?
    private let eventsContinuation: AsyncStream<TailnetEvent>.Continuation
    private let eventsStream: AsyncStream<TailnetEvent>

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

    private func ensureGo() async -> GoTailnetBackend {
        if let goBackend {
            return goBackend
        }
        TailnetDebug.post("LazyGo: creating TailnetCore bridge (BridgeNewBridge)…")
        let backend = GoTailnetBackend()
        goBackend = backend
        TailnetDebug.post("LazyGo: TailnetCore bridge ready")
        forwardEventsTask = Task {
            let events = backend.events
            for await event in events {
                eventsContinuation.yield(event)
            }
        }
        return backend
    }

    public func start(profile: TailnetProfile, stateDirectory: URL) async throws {
        TailnetDebug.post("LazyGo: start requested for hostname=\(profile.hostname)")
        try await ensureGo().start(profile: profile, stateDirectory: stateDirectory)
        TailnetDebug.post("LazyGo: start returned to Swift")
    }

    public func stop(profileID: UUID) async {
        guard let goBackend else { return }
        await goBackend.stop(profileID: profileID)
    }

    public func state(profileID: UUID) async -> TailnetState {
        guard let goBackend else { return .stopped }
        return await goBackend.state(profileID: profileID)
    }

    public func peers(profileID: UUID) async throws -> [TailnetPeer] {
        try await ensureGo().peers(profileID: profileID)
    }

    public func dialTCP(profileID: UUID, host: String, port: Int) async throws -> any TailnetConnection {
        try await ensureGo().dialTCP(profileID: profileID, host: host, port: port)
    }

    public func openLoopbackRelay(profileID: UUID, host: String, port: Int) async throws -> Int {
        try await ensureGo().openLoopbackRelay(profileID: profileID, host: host, port: port)
    }

    public func verifyDistributedHostKey(
        profileID: UUID,
        hostname: String,
        port: Int,
        fingerprintSHA256: String
    ) async -> Bool {
        guard let goBackend else { return false }
        return await goBackend.verifyDistributedHostKey(
            profileID: profileID,
            hostname: hostname,
            port: port,
            fingerprintSHA256: fingerprintSHA256
        )
    }
}
