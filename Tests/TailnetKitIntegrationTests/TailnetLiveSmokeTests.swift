import XCTest
import TailnetKitCore
import TailnetKitEmbedded

/// Live smoke tests that drive the embedded backend against a real Tailscale
/// control plane on macOS. Skipped unless TAILNET_INTEGRATION=1 (they need network).
///
/// These are the parity net for the c-archive migration: green here on the current
/// gomobile boundary, then green again on the new boundary should mean equivalent
/// behavior.
final class TailnetLiveSmokeTests: XCTestCase {
    private func requireIntegration() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["TAILNET_INTEGRATION"] == "1",
            "set TAILNET_INTEGRATION=1 to run live tailnet tests"
        )
    }

    /// Tier 1 — no credentials. Proves the bridge loads, the Go runtime runs, tsnet
    /// starts, the control plane is reachable, and a login URL comes back through the
    /// Swift API and JSON state decode. Never completes login, so nothing joins the tailnet.
    func testEmbeddedBackendReachesLogin() async throws {
        try requireIntegration()

        let backend = GoTailnetBackend()
        let directory = freshStateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await backend.configure(profile: TailnetProfile(hostname: "tnk-smoke"), stateDirectory: directory)
        try await backend.start()

        let state = try await waitForState(backend, timeout: 45) { state in
            switch state {
            case .needsLogin, .running, .needsDeviceApproval: return true
            default: return false
            }
        }
        if case .needsLogin(let url) = state {
            print("[smoke] login URL: \(url.absoluteString)")
        }
        await backend.stop()
    }

    /// Tier 2 — interactive. Prints a login URL, waits for you to authenticate, then
    /// lists peers. Gated behind TAILNET_INTERACTIVE=1; creates a real node you can
    /// remove from the admin console afterward.
    func testEmbeddedBackendFullPathInteractive() async throws {
        try requireIntegration()
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["TAILNET_INTERACTIVE"] == "1",
            "set TAILNET_INTERACTIVE=1 and authenticate when prompted"
        )

        let backend = GoTailnetBackend()
        let directory = freshStateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await backend.configure(profile: TailnetProfile(hostname: "tnk-smoke"), stateDirectory: directory)
        try await backend.start()

        let state = try await waitForState(backend, timeout: 30) { state in
            if case .needsLogin = state { return true }
            if case .running = state { return true }
            return false
        }
        if case .needsLogin(let url) = state {
            print("\n[smoke] Open this URL and authenticate; the test continues once you're running:\n  \(url.absoluteString)\n")
            _ = try await waitForState(backend, timeout: 300) { state in
                if case .running = state { return true }
                return false
            }
        }

        let peers = try await backend.peers()
        print("[smoke] running; peers visible: \(peers.count)")
        await backend.stop()
    }

    // MARK: - Helpers

    private func freshStateDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tnk-smoke-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func waitForState(
        _ backend: GoTailnetBackend,
        timeout: TimeInterval,
        until predicate: (TailnetState) -> Bool
    ) async throws -> TailnetState {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let state = await backend.currentState()
            if predicate(state) { return state }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        let last = await backend.currentState()
        XCTFail("timed out after \(timeout)s; last state: \(last)")
        return last
    }
}
