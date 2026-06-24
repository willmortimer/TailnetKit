import Foundation
import TailnetCore
import TailnetKit

/// tsnet backend backed by Go TailnetCore.xcframework (gomobile).
public actor GoTailnetBackend: TailnetBackend {
    public nonisolated let kind: TailnetBackendKind = .embedded

    private let bridgeBox: TailnetBridgeBox
    private let eventsContinuation: AsyncStream<TailnetEvent>.Continuation
    private let eventsStream: AsyncStream<TailnetEvent>
    private let listener: GoEventListener

    public init() {
        guard let bridge = BridgeNewBridge() else {
            fatalError("TailnetCore BridgeNewBridge returned nil")
        }
        var continuation: AsyncStream<TailnetEvent>.Continuation!
        let stream = AsyncStream<TailnetEvent> { cont in
            continuation = cont
        }
        self.bridgeBox = TailnetBridgeBox(bridge: bridge)
        self.eventsStream = stream
        self.eventsContinuation = continuation
        self.listener = GoEventListener(continuation: continuation)
        bridge.setListener(listener)
    }

    public nonisolated var events: AsyncStream<TailnetEvent> {
        eventsStream
    }

    public func start(profile: TailnetProfile, stateDirectory: URL) async throws {
        let payload = GoProfilePayload(
            id: profile.id.uuidString,
            displayName: profile.displayName,
            hostname: profile.hostname,
            controlURL: profile.controlURL,
            stateDir: stateDirectory.path
        )
        let data = try JSONEncoder().encode(payload)
        guard let json = String(data: data, encoding: .utf8) else {
            throw TailnetError.unreachable("Failed to encode profile")
        }
        Task { @MainActor in
            eventsContinuation.yield(.state(.starting))
        }
        TailnetDebug.post("GoTailnet: calling bridge.start (tsnet Start + status poll)")
        let box = bridgeBox
        try await TailnetBridgeExecutor.run {
            try box.bridge.start(json)
        }
        TailnetDebug.post("GoTailnet: bridge.start returned")
    }

    public func stop(profileID: UUID) async {
        let box = bridgeBox
        let profileIDString = profileID.uuidString
        _ = await TailnetBridgeExecutor.run {
            try? box.bridge.stop(profileIDString)
        }
        Task { @MainActor in
            eventsContinuation.yield(.state(.stopped))
        }
    }

    public func state(profileID: UUID) async -> TailnetState {
        let box = bridgeBox
        let profileIDString = profileID.uuidString
        return await TailnetBridgeExecutor.run {
            var error: NSError?
            let json = box.bridge.stateJSON(profileIDString, error: &error)
            if let error {
                return .failed(error.localizedDescription)
            }
            return GoTailnetStateDecoder.decodeStateJSON(json)
        }
    }

    public func peers(profileID: UUID) async throws -> [TailnetPeer] {
        let box = bridgeBox
        let profileIDString = profileID.uuidString
        return try await TailnetBridgeExecutor.run {
            var error: NSError?
            let json = box.bridge.peersJSON(profileIDString, error: &error)
            if let error {
                throw TailnetError.unreachable(error.localizedDescription)
            }
            guard let data = json.data(using: .utf8) else { return [] }
            let goPeers = try JSONDecoder().decode([GoPeer].self, from: data)
            return goPeers.map { $0.asTailnetPeer() }
        }
    }

    public func dialTCP(profileID: UUID, host: String, port: Int) async throws -> any TailnetConnection {
        let box = bridgeBox
        let profileIDString = profileID.uuidString
        let connID: Int64 = try await TailnetBridgeExecutor.run {
            var connID: Int64 = 0
            try box.bridge.dialTCP(profileIDString, host: host, port: Int64(port), ret0_: &connID)
            return connID
        }
        return GoTailnetConnection(bridgeBox: box, connID: connID)
    }

    public func openLoopbackRelay(profileID: UUID, host: String, port: Int) async throws -> Int {
        let box = bridgeBox
        let profileIDString = profileID.uuidString
        return try await TailnetBridgeExecutor.run {
            var relayPort: Int64 = 0
            try box.bridge.openLoopbackRelay(profileIDString, host: host, port: Int64(port), ret0_: &relayPort)
            return Int(relayPort)
        }
    }

    public func verifyDistributedHostKey(
        profileID: UUID,
        hostname: String,
        port: Int,
        fingerprintSHA256: String
    ) async -> Bool {
        let box = bridgeBox
        return await TailnetBridgeExecutor.run {
            box.bridge.verifySSHHostKey(
                profileID.uuidString,
                hostname: hostname,
                port: Int64(port),
                fingerprint: fingerprintSHA256
            )
        }
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
