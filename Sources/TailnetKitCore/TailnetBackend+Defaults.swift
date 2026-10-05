import Foundation

extension TailnetBackend {
    public func dialUDP(host: String, port: Int) async throws -> any TailnetDatagramConnection {
        throw TailnetError.destinationUnreachable("UDP unavailable")
    }
    public func services() async throws -> [TailnetService] { [] }

    public func pingPath(peerIP: String) async throws -> TailnetPath {
        throw TailnetError.destinationUnreachable("path probing unavailable")
    }

    /// Default identity teardown is a plain stop. Backends that persist node state
    /// (e.g. the embedded backend) override this to also delete it.
    public func destroyIdentity() async throws {
        await stop()
    }

    public func verifyHostKey(hostname: String, port: Int, fingerprintSHA256: String) async -> Bool {
        false
    }

    public func openLoopbackRelay(host: String, port: Int) async throws -> Int {
        throw TailnetError.relayFailed("requires the embedded TailnetCore backend")
    }

    public func closeLoopbackRelay(port: Int) async {}
}
