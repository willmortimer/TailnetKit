import XCTest
@testable import TailnetKit

final class InMemoryBackendTests: XCTestCase {
    func testLifecycleStartPeersStop() async throws {
        let backend = InMemoryTailnetBackend(peers: [
            TailnetPeer(
                id: "n1",
                dnsName: "host.example.ts.net.",   // trailing dot, as tailnet status reports it
                hostName: "host",
                tailscaleIP: "100.64.0.9",
                online: true
            ),
        ])
        let profile = TailnetProfile.main
        let dir = FileManager.default.temporaryDirectory

        // Before start: stopped, and peers() surfaces .notRunning.
        let stopped = await backend.state(profileID: profile.id)
        XCTAssertEqual(stopped, .stopped)
        do {
            _ = try await backend.peers(profileID: profile.id)
            XCTFail("expected peers() to throw before start")
        } catch let error as TailnetError {
            guard case .notRunning = error else {
                return XCTFail("expected .notRunning, got \(error)")
            }
        }

        // After start: running with the stub address; peers() returns the seeded list.
        try await backend.start(profile: profile, stateDirectory: dir)
        let running = await backend.state(profileID: profile.id)
        XCTAssertEqual(running, .running(ipv4: "100.64.0.2", ipv6: nil))

        let peers = try await backend.peers(profileID: profile.id)
        XCTAssertEqual(peers.count, 1)
        XCTAssertEqual(peers.first?.connectHostname, "host.example.ts.net") // trailing dot dropped

        // After stop: back to stopped.
        await backend.stop(profileID: profile.id)
        let final = await backend.state(profileID: profile.id)
        XCTAssertEqual(final, .stopped)
    }
}

final class TailnetProfileCodingTests: XCTestCase {
    func testRoundTripPreservesAllFields() throws {
        let profile = TailnetProfile(
            id: TailnetProfile.mainID,
            displayName: "Personal",
            hostname: "my-device",
            controlURL: "https://controlplane.example"
        )
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(TailnetProfile.self, from: data)
        XCTAssertEqual(decoded, profile)
    }

    func testMinimalPayloadDecodes() throws {
        // controlURL is optional; a payload without it must still decode.
        let json = #"{"id":"00000000-0000-0000-0000-000000000001","displayName":"X","hostname":"x"}"#
        let decoded = try JSONDecoder().decode(TailnetProfile.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.id, TailnetProfile.mainID)
        XCTAssertEqual(decoded.hostname, "x")
        XCTAssertNil(decoded.controlURL)
    }
}
