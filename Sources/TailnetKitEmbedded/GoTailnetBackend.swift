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
    private var profile: TailnetProfile?
    private var stateDirectory: URL?

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

    public func configure(profile: TailnetProfile, stateDirectory: URL) async throws {
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

    public func stop() async {
        guard let profile else { return }
        let box = bridgeBox
        let profileIDString = profile.id.uuidString
        _ = await TailnetBridgeExecutor.run {
            try? box.bridge.stop(profileIDString)
        }
        Task { @MainActor in
            eventsContinuation.yield(.state(.stopped))
        }
    }

    public func currentState() async -> TailnetState {
        guard let profile else { return .stopped }
        let box = bridgeBox
        let profileIDString = profile.id.uuidString
        return await TailnetBridgeExecutor.run {
            var error: NSError?
            let json = box.bridge.stateJSON(profileIDString, error: &error)
            if let error {
                return .failed(error.localizedDescription)
            }
            return GoTailnetStateDecoder.decodeStateJSON(json)
        }
    }

    public func peers() async throws -> [TailnetPeer] {
        let profile = try requireProfile()
        let box = bridgeBox
        let profileIDString = profile.id.uuidString
        return try await TailnetBridgeExecutor.run {
            var error: NSError?
            let json = box.bridge.peersJSON(profileIDString, error: &error)
            if let error {
                throw TailnetError.controlPlaneUnavailable(error.localizedDescription)
            }
            guard let data = json.data(using: .utf8) else { return [] }
            let goPeers = try JSONDecoder().decode([GoPeer].self, from: data)
            return goPeers.map { $0.asTailnetPeer() }
        }
    }

    public func dialTCP(host: String, port: Int) async throws -> any TailnetConnection {
        let profile = try requireProfile()
        let box = bridgeBox
        let profileIDString = profile.id.uuidString
        let connID: Int64 = try await TailnetBridgeExecutor.run {
            var connID: Int64 = 0
            try box.bridge.dialTCP(profileIDString, host: host, port: Int64(port), ret0_: &connID)
            return connID
        }
        return GoTailnetConnection(bridgeBox: box, connID: connID)
    }

    public func openLoopbackRelay(host: String, port: Int) async throws -> Int {
        let profile = try requireProfile()
        let box = bridgeBox
        let profileIDString = profile.id.uuidString
        return try await TailnetBridgeExecutor.run {
            var relayPort: Int64 = 0
            try box.bridge.openLoopbackRelay(profileIDString, host: host, port: Int64(port), ret0_: &relayPort)
            return Int(relayPort)
        }
    }

    public func verifyHostKey(hostname: String, port: Int, fingerprintSHA256: String) async -> Bool {
        guard let profile else { return false }
        let box = bridgeBox
        let profileIDString = profile.id.uuidString
        return await TailnetBridgeExecutor.run {
            box.bridge.verifySSHHostKey(
                profileIDString,
                hostname: hostname,
                port: Int64(port),
                fingerprint: fingerprintSHA256
            )
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
