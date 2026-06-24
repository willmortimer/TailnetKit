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

/// Owns one embedded-tailnet identity: the selected backend, the active profile, and
/// lifecycle. Constructed and injected by the app; there is no shared singleton.
public actor TailnetClient {
    private let backend: any TailnetBackend
    private var profile: TailnetProfile?
    private var stateDirectory: URL?

    public init(backend: any TailnetBackend) {
        self.backend = backend
    }

    public nonisolated var backendKind: TailnetBackendKind {
        backend.kind
    }

    /// Lifecycle states. Iterate this once — it drains the backend's event stream.
    public nonisolated var states: AsyncStream<TailnetState> {
        let events = backend.events
        return AsyncStream { continuation in
            let task = Task {
                for await event in events {
                    if case .state(let state) = event {
                        continuation.yield(state)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func configure(profile: TailnetProfile) async throws {
        let directory = try Self.applicationSupportStateDirectory(profileID: profile.id)
        self.profile = profile
        self.stateDirectory = directory
        try await backend.configure(profile: profile, stateDirectory: directory)
    }

    public func start() async throws {
        guard profile != nil else {
            throw TailnetError.unreachable("Configure a profile before starting")
        }
        try await backend.start()
    }

    public func ensureRunning() async throws {
        if case .running = await backend.currentState() { return }
        try await start()
    }

    public func stop() async {
        await backend.stop()
    }

    public func destroyIdentity() async throws {
        try await backend.destroyIdentity()
    }

    public func currentState() async -> TailnetState {
        await backend.currentState()
    }

    public func peers() async throws -> [TailnetPeer] {
        try await backend.peers()
    }

    public func dialTCP(host: String, port: Int) async throws -> any TailnetConnection {
        try await backend.dialTCP(host: host, port: port)
    }

    public func openLoopbackRelay(to destination: TailnetDestination) async throws -> TailnetRelay {
        let port = try await backend.openLoopbackRelay(host: destination.host, port: destination.port)
        return TailnetRelay(host: "127.0.0.1", port: port, destination: destination)
    }

    public func verifyHostKey(hostname: String, port: Int, fingerprintSHA256: String) async -> Bool {
        await backend.verifyHostKey(hostname: hostname, port: port, fingerprintSHA256: fingerprintSHA256)
    }

    public func resolvedStateDirectoryPath() -> String? {
        stateDirectory?.path
    }

    /// Per-profile state directory under Application Support. File protection is applied
    /// best-effort (a no-op on platforms without data protection).
    public static func applicationSupportStateDirectory(
        profileID: UUID = TailnetProfile.mainID,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw TailnetError.unreachable("Application Support unavailable")
        }
        let directory = base
            .appendingPathComponent("TailnetState", isDirectory: true)
            .appendingPathComponent(profileID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directory.path
        )
        return directory
    }

    public static func sanitizeHostname(_ input: String) -> String {
        let lowered = input.lowercased()
        let allowed = lowered.map { character -> Character in
            if character.isLetter || character.isNumber || character == "-" { return character }
            return "-"
        }
        var collapsed = String(allowed)
        while collapsed.contains("--") {
            collapsed = collapsed.replacingOccurrences(of: "--", with: "-")
        }
        return String(collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(63))
    }
}
