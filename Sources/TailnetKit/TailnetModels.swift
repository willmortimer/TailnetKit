import Foundation

/// A configured embedded-tailnet identity. Transport-only: app concerns such as
/// auto-connect policy or SSH usernames belong to the consuming app, not here.
public struct TailnetProfile: Codable, Identifiable, Equatable, Sendable {
    public static let mainID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    public var id: UUID
    public var displayName: String
    public var hostname: String
    public var controlURL: String?

    public init(
        id: UUID = TailnetProfile.mainID,
        displayName: String = "TailnetKit",
        hostname: String = "tailnetkit-device",
        controlURL: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.hostname = hostname
        self.controlURL = controlURL
    }

    public static var main: TailnetProfile { TailnetProfile() }
}

public enum TailnetState: Sendable, Equatable {
    case stopped
    case starting
    case needsLogin(URL)
    case needsDeviceApproval
    case running(ipv4: String?, ipv6: String?)
    case reauthRequired(URL)
    case failed(String)
}

public enum TailnetEvent: Sendable {
    case state(TailnetState)
    case loginURL(URL)
    case error(String)
}

public struct TailnetPeer: Identifiable, Sendable, Codable, Equatable {
    public var id: String
    public var dnsName: String
    public var hostName: String
    public var tailscaleIP: String
    public var os: String?
    public var online: Bool
    public var sshEnabled: Bool

    public init(
        id: String,
        dnsName: String,
        hostName: String,
        tailscaleIP: String,
        os: String? = nil,
        online: Bool = false,
        sshEnabled: Bool = false
    ) {
        self.id = id
        self.dnsName = dnsName
        self.hostName = hostName
        self.tailscaleIP = tailscaleIP
        self.os = os
        self.online = online
        self.sshEnabled = sshEnabled
    }

    public var connectHostname: String {
        let raw = !dnsName.isEmpty ? dnsName : tailscaleIP
        return raw.hasSuffix(".") ? String(raw.dropLast()) : raw
    }
}

public protocol TailnetConnection: Sendable {
    func read(maxBytes: Int) async throws -> Data
    func write(_ data: Data) async throws
    func close() async
}

public protocol TailnetBackend: Sendable {
    nonisolated var kind: TailnetBackendKind { get }
    func verifyDistributedHostKey(
        profileID: UUID,
        hostname: String,
        port: Int,
        fingerprintSHA256: String
    ) async -> Bool
    func start(profile: TailnetProfile, stateDirectory: URL) async throws
    func stop(profileID: UUID) async
    func state(profileID: UUID) async -> TailnetState
    func peers(profileID: UUID) async throws -> [TailnetPeer]
    func dialTCP(profileID: UUID, host: String, port: Int) async throws -> any TailnetConnection
    func openLoopbackRelay(profileID: UUID, host: String, port: Int) async throws -> Int
    var events: AsyncStream<TailnetEvent> { get async }
}
