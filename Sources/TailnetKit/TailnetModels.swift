import Foundation

public struct TailnetProfile: Codable, Identifiable, Equatable, Sendable {
    public static let mainID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    public var id: UUID
    public var displayName: String
    public var hostname: String
    public var controlURL: String?
    /// When true, reconnect embedded tailnet on app launch if it was previously authenticated.
    public var autoConnectOnLaunch: Bool
    /// Default SSH username for hosts added from the tailnet peer list (iOS `NSUserName()` is not useful).
    public var defaultSSHUsername: String

    public init(
        id: UUID = TailnetProfile.mainID,
        displayName: String = "TailnetKit",
        hostname: String = "tailnetkit-device",
        controlURL: String? = nil,
        autoConnectOnLaunch: Bool = true,
        defaultSSHUsername: String = ""
    ) {
        self.id = id
        self.displayName = displayName
        self.hostname = hostname
        self.controlURL = controlURL
        self.autoConnectOnLaunch = autoConnectOnLaunch
        self.defaultSSHUsername = defaultSSHUsername
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        hostname = try container.decode(String.self, forKey: .hostname)
        controlURL = try container.decodeIfPresent(String.self, forKey: .controlURL)
        autoConnectOnLaunch = try container.decodeIfPresent(Bool.self, forKey: .autoConnectOnLaunch) ?? true
        defaultSSHUsername = try container.decodeIfPresent(String.self, forKey: .defaultSSHUsername) ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, hostname, controlURL, autoConnectOnLaunch, defaultSSHUsername
    }

    public static var main: TailnetProfile {
        TailnetProfile()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(hostname, forKey: .hostname)
        try container.encodeIfPresent(controlURL, forKey: .controlURL)
        try container.encode(autoConnectOnLaunch, forKey: .autoConnectOnLaunch)
        try container.encode(defaultSSHUsername, forKey: .defaultSSHUsername)
    }
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
