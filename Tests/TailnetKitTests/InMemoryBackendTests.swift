import XCTest
import TailnetKitCore
import TailnetKitTesting

final class InMemoryBackendTests: XCTestCase {
    func testLifecycleConfigureStartPeersStop() async throws {
        let backend = InMemoryTailnetBackend(peers: [
            TailnetPeer(
                id: "n1",
                dnsName: "host.example.ts.net.",   // trailing dot, as tailnet status reports it
                hostName: "host",
                tailscaleIP: "100.64.0.9",
                online: true
            ),
        ])
        let dir = FileManager.default.temporaryDirectory

        // Before start: stopped, and peers() surfaces .notRunning.
        let stopped = await backend.currentState()
        XCTAssertEqual(stopped, .stopped)
        do {
            _ = try await backend.peers()
            XCTFail("expected peers() to throw before start")
        } catch let error as TailnetError {
            guard case .notRunning = error else {
                return XCTFail("expected .notRunning, got \(error)")
            }
        }

        // After configure + start: running with the stub address; peers() returns the list.
        try await backend.configure(profile: .main, stateDirectory: dir)
        try await backend.start()
        let running = await backend.currentState()
        XCTAssertEqual(running, .running(TailnetIdentity(hostname: "tailnetkit-device", ipv4: "100.64.0.2")))

        let peers = try await backend.peers()
        XCTAssertEqual(peers.count, 1)
        XCTAssertEqual(peers.first?.connectHostname, "host.example.ts.net") // trailing dot dropped

        // After stop: back to stopped.
        await backend.stop()
        let final = await backend.currentState()
        XCTAssertEqual(final, .stopped)
    }
}

final class TailnetClientTests: XCTestCase {
    func testClientDrivesInMemoryBackend() async throws {
        let client = TailnetClient(backend: InMemoryTailnetBackend(peers: [
            TailnetPeer(id: "n1", dnsName: "h.example.ts.net.", hostName: "h", tailscaleIP: "100.64.0.9", online: true),
        ]))

        try await client.configure(profile: .main)
        try await client.start()
        let runningState = await client.currentState()
        XCTAssertEqual(runningState, .running(TailnetIdentity(hostname: "tailnetkit-device", ipv4: "100.64.0.2")))

        let peers = try await client.peers()
        XCTAssertEqual(peers.count, 1)

        await client.stop()
        let stoppedState = await client.currentState()
        XCTAssertEqual(stoppedState, .stopped)
    }

    func testStartBeforeConfigureThrows() async throws {
        let client = TailnetClient(backend: InMemoryTailnetBackend())
        do {
            try await client.start()
            XCTFail("expected start() to throw before configure()")
        } catch let error as TailnetError {
            guard case .notConfigured = error else {
                return XCTFail("expected .notConfigured, got \(error)")
            }
        }
    }

    func testDestroyIdentityStops() async throws {
        let client = TailnetClient(backend: InMemoryTailnetBackend())
        try await client.configure(profile: .main)
        try await client.start()
        try await client.destroyIdentity()
        let state = await client.currentState()
        XCTAssertEqual(state, .stopped)
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
