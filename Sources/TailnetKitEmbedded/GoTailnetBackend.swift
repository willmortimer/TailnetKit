import Foundation
import TailnetCore
import TailnetKitCore

/// tsnet backend backed by the Go TailnetCore.xcframework (c-archive / flat C ABI).
public actor GoTailnetBackend: TailnetBackend {
    /// C ABI version this Swift code requires; must match the Go side. v2 = typed structs.
    public static let bridgeProtocolVersion = 2

    public nonisolated let kind: TailnetBackendKind = .embedded

    private let bridgeBox: TailnetBridgeBox
    private let eventsContinuation: AsyncStream<TailnetEvent>.Continuation
    private let eventsStream: AsyncStream<TailnetEvent>
    private var profile: TailnetProfile?
    private var stateDirectory: URL?

    public init() {
        var continuation: AsyncStream<TailnetEvent>.Continuation!
        let stream = AsyncStream<TailnetEvent> { cont in
            continuation = cont
        }
        let sink = GoEventSink(continuation: continuation)
        guard let box = TailnetBridgeBox(sink: sink) else {
            fatalError("TailnetCore tnk_new_bridge returned 0")
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
        self.profile = profile
        self.stateDirectory = stateDirectory
    }

    public func start() async throws {
        let profile = try requireProfile()
        guard let stateDirectory else {
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
        TailnetDebug.post("GoTailnet: tnk_start returned")
    }

    public func stop() async {
        guard let profile else { return }
        let handle = bridgeBox.handle
        let profileID = profile.id.uuidString
        await TailnetBridgeExecutor.run {
            if let err = tnk_stop(handle, profileID) { tnk_free(err) }
        }
        eventsContinuation.yield(.state(.stopped))
    }

    public func destroyIdentity() async throws {
        await stop()
        if let stateDirectory {
            try? FileManager.default.removeItem(at: stateDirectory)
        }
        profile = nil
        stateDirectory = nil
    }

    public func currentState() async -> TailnetState {
        guard let profile else { return .stopped }
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

    public func verifyHostKey(hostname: String, port: Int, fingerprintSHA256: String) async -> Bool {
        guard let profile else { return false }
        let handle = bridgeBox.handle
        let profileID = profile.id.uuidString
        return await TailnetBridgeExecutor.run {
            tnk_verify_ssh_host_key(handle, profileID, hostname, Int32(port), fingerprintSHA256) == 1
        }
    }

    private func requireProfile() throws -> TailnetProfile {
        guard let profile else {
            throw TailnetError.notConfigured
        }
        return profile
    }
}
