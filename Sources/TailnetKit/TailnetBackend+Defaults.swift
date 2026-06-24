import Foundation

extension TailnetBackend {
    public func verifyDistributedHostKey(
        profileID: UUID,
        hostname: String,
        port: Int,
        fingerprintSHA256: String
    ) async -> Bool {
        _ = profileID
        _ = hostname
        _ = port
        _ = fingerprintSHA256
        return false
    }

    public func openLoopbackRelay(profileID: UUID, host: String, port: Int) async throws -> Int {
        _ = profileID
        throw TailnetError.dialFailed("Loopback relay requires embedded TailnetCore backend")
    }
}
