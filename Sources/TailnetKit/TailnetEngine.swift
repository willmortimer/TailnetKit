import Foundation

public enum TailnetError: Error, LocalizedError, Sendable {
    case notRunning
    case needsLogin(URL)
    case needsDeviceApproval
    case unreachable(String)
    case dialFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notRunning:
            return "Tailnet is not connected."
        case .needsLogin(let url):
            return "Tailnet login required: \(url.absoluteString)"
        case .needsDeviceApproval:
            return "This device must be approved in the tailnet admin console."
        case .unreachable(let message):
            return "Tailnet unreachable: \(message)"
        case .dialFailed(let message):
            return "Failed to dial over tailnet: \(message)"
        }
    }
}

public actor TailnetEngine {
    private static let lock = NSLock()
    private static var configuredShared: TailnetEngine?
    private(set) public static var configureGeneration = 0

    public static var shared: TailnetEngine {
        lock.lock()
        defer { lock.unlock() }
        if let configuredShared {
            return configuredShared
        }
        let engine = TailnetEngine()
        configuredShared = engine
        return engine
    }

    /// Replaces the process-wide engine (call once at app launch before using `.shared`).
    public static func configureShared(backend: (any TailnetBackend)?) {
        lock.lock()
        defer { lock.unlock() }
        configuredShared = TailnetEngine(backend: backend)
        configureGeneration &+= 1
    }

    private let backend: any TailnetBackend
    private var profile: TailnetProfile?
    private var stateDirectory: URL?

    public func eventsStream() async -> AsyncStream<TailnetEvent> {
        await backend.events
    }

    public init(backend: (any TailnetBackend)? = nil) {
        self.backend = backend ?? InMemoryTailnetBackend()
    }

    public var backendKind: TailnetBackendKind {
        backend.kind
    }

    public func usesEmbeddedBackend() -> Bool {
        backend.kind == .embedded
    }

    public func configure(profile: TailnetProfile) {
        self.profile = profile
    }

    public func applicationSupportStateDirectory(
        profileID: UUID = TailnetProfile.mainID,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw TailnetError.unreachable("Application Support unavailable")
        }
        let dir = base
            .appendingPathComponent("TailnetState", isDirectory: true)
            .appendingPathComponent(profileID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: dir.path
        )
        return dir
    }

    public func startIfNeeded(profile: TailnetProfile? = nil) async throws {
        let active = profile ?? self.profile ?? .main
        self.profile = active
        if stateDirectory == nil {
            stateDirectory = try applicationSupportStateDirectory(profileID: active.id)
        }
        guard let stateDirectory else { return }
        try await backend.start(profile: active, stateDirectory: stateDirectory)
    }

    public func stop() async {
        guard let profile else { return }
        await backend.stop(profileID: profile.id)
    }

    public func currentState() async -> TailnetState {
        guard let profile else { return .stopped }
        return await backend.state(profileID: profile.id)
    }

    /// Resolved tsnet state directory for diagnostics (creates the folder if needed).
    public func resolvedStateDirectoryPath(profileID: UUID = TailnetProfile.mainID) async -> String? {
        try? applicationSupportStateDirectory(profileID: profileID).path
    }

    public func peers() async throws -> [TailnetPeer] {
        guard let profile else { throw TailnetError.notRunning }
        return try await backend.peers(profileID: profile.id)
    }

    public func dialTCP(host: String, port: Int) async throws -> any TailnetConnection {
        guard let profile else { throw TailnetError.notRunning }
        return try await backend.dialTCP(profileID: profile.id, host: host, port: port)
    }

    /// Go-side loopback relay (embedded backend only). Returns local TCP port.
    public func openLoopbackRelay(host: String, port: Int) async throws -> Int {
        guard let profile else { throw TailnetError.notRunning }
        return try await backend.openLoopbackRelay(profileID: profile.id, host: host, port: port)
    }

    public func verifyDistributedHostKey(
        hostname: String,
        port: Int,
        fingerprintSHA256: String
    ) async -> Bool {
        guard let profile else { return false }
        return await backend.verifyDistributedHostKey(
            profileID: profile.id,
            hostname: hostname,
            port: port,
            fingerprintSHA256: fingerprintSHA256
        )
    }

    public static func sanitizeHostname(_ input: String) -> String {
        let lowered = input.lowercased()
        let allowed = lowered.map { char -> Character in
            if char.isLetter || char.isNumber || char == "-" { return char }
            return "-"
        }
        var collapsed = String(allowed)
        while collapsed.contains("--") {
            collapsed = collapsed.replacingOccurrences(of: "--", with: "-")
        }
        return String(collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(63))
    }
}
