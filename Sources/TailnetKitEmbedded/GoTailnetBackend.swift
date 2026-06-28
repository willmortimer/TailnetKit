import Foundation
import TailnetCore
import TailnetKitCore

/// tsnet backend backed by the Go TailnetCore.xcframework (c-archive / flat C ABI).
public actor GoTailnetBackend: TailnetBackend {
    /// C ABI version this Swift code requires; must match the Go side.
    public static let bridgeProtocolVersion = 1

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
        let payload = GoProfilePayload(
            id: profile.id.uuidString,
            displayName: profile.displayName,
            hostname: profile.hostname,
            controlURL: profile.controlURL,
            stateDir: stateDirectory.path
        )
        let data = try JSONEncoder().encode(payload)
        guard let json = String(data: data, encoding: .utf8) else {
            throw TailnetError.invalidProfile
        }
        eventsContinuation.yield(.state(.starting))
        TailnetDebug.post("GoTailnet: calling tnk_start (tsnet Start + status poll)")
        let handle = bridgeBox.handle
        try await TailnetBridgeExecutor.run {
            if let msg = tnkError(tnk_start(handle, json)) {
                throw TailnetError.upstream(msg)
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
            var out: UnsafeMutablePointer<CChar>?
            if let msg = tnkError(tnk_state_json(handle, profileID, &out)) {
                return .failed(msg)
            }
            defer { if let out { tnk_free(out) } }
            return GoTailnetStateDecoder.decodeStateJSON(out.map { String(cString: $0) })
        }
    }

    public func peers() async throws -> [TailnetPeer] {
        let profile = try requireProfile()
        let handle = bridgeBox.handle
        let profileID = profile.id.uuidString
        return try await TailnetBridgeExecutor.run {
            var out: UnsafeMutablePointer<CChar>?
            if let msg = tnkError(tnk_peers_json(handle, profileID, &out)) {
                throw TailnetError.controlPlaneUnavailable(msg)
            }
            defer { if let out { tnk_free(out) } }
            guard let out, let data = String(cString: out).data(using: .utf8) else { return [] }
            let goPeers = try JSONDecoder().decode([GoPeer].self, from: data)
            return goPeers.map { $0.asTailnetPeer() }
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

private struct GoProfilePayload: Encodable {
    let id: String
    let displayName: String
    let hostname: String
    let controlURL: String?
    let stateDir: String
}

private struct GoPeer: Decodable {
    let id: String
    let dnsName: String
    let hostName: String
    let tailscaleIP: String
    let os: String?
    let online: Bool
    let sshEnabled: Bool

    func asTailnetPeer() -> TailnetPeer {
        TailnetPeer(
            id: id,
            dnsName: dnsName,
            hostName: hostName,
            tailscaleIP: tailscaleIP,
            os: os,
            online: online,
            sshEnabled: sshEnabled
        )
    }
}
