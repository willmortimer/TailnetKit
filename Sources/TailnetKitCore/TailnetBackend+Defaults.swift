import Foundation

extension TailnetBackend {
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
}
