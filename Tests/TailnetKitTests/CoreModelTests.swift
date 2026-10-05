import Foundation
import XCTest
@testable import TailnetKitCore

final class CoreModelTests: XCTestCase {
    func testPeerObservedFieldsSurviveCodableRoundTrip() throws {
        let peer = TailnetPeer(
            id: "node-17",
            dnsName: "build.example.ts.net.",
            hostName: "build",
            tailscaleIP: "100.64.0.17",
            addresses: ["100.64.0.17", "fd7a:115c:a1e0::17"],
            tags: ["tag:dev", "tag:ci"],
            lastSeen: "2026-10-04T19:34:56Z",
            currentAddress: "192.0.2.17:41641",
            relayRegion: "sfo",
            os: "linux",
            online: true,
            sshEnabled: true
        )

        let encoded = try JSONEncoder().encode(peer)
        let decoded = try JSONDecoder().decode(TailnetPeer.self, from: encoded)

        XCTAssertEqual(decoded, peer)
        XCTAssertEqual(decoded.connectHostname, "build.example.ts.net")
    }

    func testPeerFallsBackToIPWhenDNSNameIsMissing() {
        let peer = TailnetPeer(
            id: "node-18",
            dnsName: "",
            hostName: "build",
            tailscaleIP: "100.64.0.18"
        )

        XCTAssertEqual(peer.connectHostname, "100.64.0.18")
    }

    func testPathDirectnessRequiresObservedEndpoint() throws {
        let direct = TailnetPath(
            latencyMillis: 12.5,
            endpoint: "192.0.2.17:41641",
            peerRelay: nil,
            derpRegion: nil
        )
        let relayed = TailnetPath(
            latencyMillis: 81,
            endpoint: nil,
            peerRelay: "peer-relay",
            derpRegion: "sfo"
        )
        let emptyEndpoint = TailnetPath(
            latencyMillis: 0,
            endpoint: "",
            peerRelay: nil,
            derpRegion: nil
        )

        XCTAssertTrue(direct.isDirect)
        XCTAssertFalse(relayed.isDirect)
        XCTAssertFalse(emptyEndpoint.isDirect)

        let decoded = try JSONDecoder().decode(
            TailnetPath.self,
            from: JSONEncoder().encode(relayed)
        )
        XCTAssertEqual(decoded, relayed)
    }
}
