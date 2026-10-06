import Foundation
import TailnetCore
import TailnetKitCore

/// tsnet backend backed by the Go TailnetCore.xcframework (c-archive / flat C ABI).
public actor GoTailnetBackend: TailnetBackend {
    /// C ABI version this Swift code requires; must match the Go side. v3 adds stream half-close.
    public static let bridgeProtocolVersion = 3

    public nonisolated let kind: TailnetBackendKind = .embedded

    private let bridgeBox: TailnetBridgeBox
    private let eventsContinuation: AsyncStream<TailnetEvent>.Continuation
    private let eventsStream: AsyncStream<TailnetEvent>
    private var phase = TailnetRuntimePhase()
    private var stateDirectory: URL?
    private var startWaiters: [CheckedContinuation<Void, Error>] = []
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private var startBridgeFinished: CheckedContinuation<Void, Never>?

    public init() throws {
        var continuation: AsyncStream<TailnetEvent>.Continuation!
        let stream = AsyncStream<TailnetEvent> { cont in
            continuation = cont
        }
        let sink = GoEventSink(continuation: continuation)
        guard let box = TailnetBridgeBox(sink: sink) else {
            throw TailnetError.bridgeUnavailable
        }
        self.bridgeBox = box
        self.eventsStream = stream
        self.eventsContinuation = continuation
    }

    public nonisolated var events: AsyncStream<TailnetEvent> {
        eventsStream
    }

    public func configure(profile: TailnetProfile, stateDirectory: URL) async throws {
        let found = Int(tnk_protocol_version())
        guard found == Self.bridgeProtocolVersion else {
            throw TailnetError.bridgeVersionMismatch(expected: Self.bridgeProtocolVersion, found: found)
        }
        try phase.configure(profile)
        self.stateDirectory = stateDirectory
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
            guard let stateDirectory else {
                phase.failStart(profileID: profile.id)
                throw TailnetError.stateDirectoryUnavailable("not configured")
            }
            let id = profile.id.uuidString
            let displayName = profile.displayName
            let hostname = profile.hostname
            let controlURL = profile.controlURL
            let stateDir = stateDirectory.path
            let handle = bridgeBox.handle
            eventsContinuation.yield(.state(.starting))
            TailnetDebug.post("GoTailnet: calling tnk_start (tsnet Start + status poll)")
            do {
                try await TailnetBridgeExecutor.run {
                    try withTnkProfile(
                        id: id, displayName: displayName, hostname: hostname,
                        controlURL: controlURL, stateDir: stateDir
                    ) { profilePtr in
                        if let msg = tnkError(tnk_start(handle, profilePtr)) {
                            throw TailnetError.upstream(msg)
                        }
                    }
                }
                if !phase.finishStart(profileID: profile.id) {
                    startBridgeFinished?.resume()
                    startBridgeFinished = nil
                }
                resumeStartWaiters(.success(()))
                TailnetDebug.post("GoTailnet: tnk_start returned")
            } catch {
                phase.failStart(profileID: profile.id)
                startBridgeFinished?.resume()
                startBridgeFinished = nil
                resumeStartWaiters(.failure(error))
                throw error
            }
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
            let handle = bridgeBox.handle
            let profileID = profile.id.uuidString
            await TailnetBridgeExecutor.run {
                if let err = tnk_stop(handle, profileID) { tnk_free(err) }
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

    public func destroyIdentity() async throws {
        await stop()
        if let stateDirectory {
            try? FileManager.default.removeItem(at: stateDirectory)
        }
        phase.destroy()
        stateDirectory = nil
    }

    public func currentState() async -> TailnetState {
        guard let profile = phase.profile else { return .stopped }
        let handle = bridgeBox.handle
        let profileID = profile.id.uuidString
        return await TailnetBridgeExecutor.run {
            var state = tnk_state()
            if let msg = tnkError(tnk_get_state(handle, profileID, &state)) {
                return .failed(msg)
            }
            defer { tnk_free_state(&state) }
            return mapTailnetState(state)
        }
    }

    public func peers() async throws -> [TailnetPeer] {
        let profile = try requireProfile()
        let handle = bridgeBox.handle
        let profileID = profile.id.uuidString
        return try await TailnetBridgeExecutor.run {
            var array: UnsafeMutablePointer<tnk_peer>?
            var count: Int32 = 0
            if let msg = tnkError(tnk_get_peers(handle, profileID, &array, &count)) {
                throw TailnetError.controlPlaneUnavailable(msg)
            }
            defer { tnk_free_peers(array, count) }
            guard let array, count > 0 else { return [] }
            return (0..<Int(count)).map { mapTailnetPeer(array[$0]) }
        }
    }

    public func services() async throws -> [TailnetService] {
        let profile = try requireProfile()
        let handle = bridgeBox.handle
        let profileID = profile.id.uuidString
        return try await TailnetBridgeExecutor.run {
            var json: UnsafeMutablePointer<CChar>?
            if let msg = tnkError(tnk_get_services_json(handle, profileID, &json)) {
                throw TailnetError.upstream(msg)
            }
            guard let json else { return [] }
            defer { tnk_free(json) }
            return try JSONDecoder().decode([TailnetService].self, from: Data(String(cString: json).utf8))
        }
    }

    public func pingPath(peerIP: String) async throws -> TailnetPath {
        let profile = try requireProfile()
        let handle = bridgeBox.handle
        let profileID = profile.id.uuidString
        return try await TailnetBridgeExecutor.run {
            var json: UnsafeMutablePointer<CChar>?
            if let msg = tnkError(tnk_ping_path_json(handle, profileID, peerIP, &json)) {
                throw TailnetError.upstream(msg)
            }
            guard let json else { throw TailnetError.upstream("empty path response") }
            defer { tnk_free(json) }
            return try JSONDecoder().decode(TailnetPath.self, from: Data(String(cString: json).utf8))
        }
    }

    public func dialTCP(host: String, port: Int) async throws -> any TailnetConnection {
        let profile = try requireProfile()
        let handle = bridgeBox.handle
        let profileID = profile.id.uuidString
        let connID: Int64 = try await TailnetBridgeExecutor.run {
            var cid: Int64 = 0
            if let msg = tnkError(tnk_dial_tcp(handle, profileID, host, Int32(port), &cid)) {
                throw TailnetError.upstream(msg)
            }
            return cid
        }
        return GoTailnetConnection(bridgeBox: bridgeBox, connID: connID)
    }

    public func dialUDP(host: String, port: Int) async throws -> any TailnetDatagramConnection {
        let profile = try requireProfile()
        let handle = bridgeBox.handle
        let profileID = profile.id.uuidString
        let connID: Int64 = try await TailnetBridgeExecutor.run {
            var id: Int64 = 0
            if let message = tnkError(tnk_dial_udp(handle, profileID, host, Int32(port), &id)) {
                throw TailnetError.upstream(message)
            }
            return id
        }
        return GoTailnetDatagramConnection(bridgeBox: bridgeBox, connID: connID)
    }

    public func openLoopbackRelay(host: String, port: Int) async throws -> Int {
        let profile = try requireProfile()
        let handle = bridgeBox.handle
        let profileID = profile.id.uuidString
        return try await TailnetBridgeExecutor.run {
            var relayPort: Int32 = 0
            if let msg = tnkError(tnk_open_loopback_relay(handle, profileID, host, Int32(port), &relayPort)) {
                throw TailnetError.relayFailed(msg)
            }
            return Int(relayPort)
        }
    }

    public func closeLoopbackRelay(port: Int) async {
        let handle = bridgeBox.handle
        await TailnetBridgeExecutor.run {
            if let err = tnk_close_loopback_relay(handle, Int32(port)) { tnk_free(err) }
        }
    }

    public func verifyHostKey(hostname: String, port: Int, fingerprintSHA256: String) async -> Bool {
        guard let profile = phase.profile else { return false }
        let handle = bridgeBox.handle
        let profileID = profile.id.uuidString
        return await TailnetBridgeExecutor.run {
            tnk_verify_ssh_host_key(handle, profileID, hostname, Int32(port), fingerprintSHA256) == 1
        }
    }

    private func requireProfile() throws -> TailnetProfile {
        guard let profile = phase.profile else {
            throw TailnetError.notConfigured
        }
        return profile
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
