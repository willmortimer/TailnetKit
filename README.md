# TailnetKit

TailnetKit embeds an application-scoped [Tailscale](https://tailscale.com) node into Apple-platform apps. It wraps Tailscale's Go `tsnet` implementation behind a typed Swift concurrency API and ships the Go runtime as a prebuilt XCFramework.

It lets an app reach private tailnet services directly — without routing the whole device through the system Tailscale VPN, and without the user installing Tailscale at all. The app gets its own tailnet identity, scoped to exactly the services you authorize.

TailnetKit is an independent project built on Tailscale's open-source code. It is not an official Tailscale SDK.

Typical uses:

- SSH and terminal clients
- Internal admin and observability tools
- Private API, database, and infrastructure clients
- Media clients for private servers (e.g. Jellyfin)
- Apps that need an app-specific tailnet identity with its own ACLs

## Installation

Add the package in `Package.swift`:

```swift
.package(url: "https://github.com/willmortimer/TailnetKit.git", from: "0.1.0")
```

Then depend on the products you need:

- `TailnetKitCore` — models, `TailnetClient`, errors (no binary dependency)
- `TailnetKitEmbedded` — the embedded tsnet backend (pulls in `TailnetCore.xcframework`)
- `TailnetKitTesting` — an in-memory backend for tests and previews

## Quick start

```swift
import TailnetKitCore
import TailnetKitEmbedded

let client = TailnetClient(backend: GoTailnetBackend())
try await client.configure(profile: TailnetProfile(hostname: "my-app"))

Task {
    for await state in client.states {
        switch state {
        case .needsLogin(let url):
            print("Open:", url)                     // present to the user to sign in
        case .needsDeviceApproval:
            print("Approve this device in the tailnet admin console")
        case .running(let identity):
            print("Connected as", identity.hostname)
        case .failed(let message):
            print("Tailnet error:", message)
        default:
            break
        }
    }
}

try await client.start()

// Bridge a private service to a local TCP port your existing client can connect to.
let relay = try await client.openLoopbackRelay(
    to: TailnetDestination(host: "server.example.ts.net", port: 22)
)
print("Connect to \(relay.host):\(relay.port)")
```

For tests and SwiftUI previews, swap the backend without touching the rest of your code:

```swift
import TailnetKitTesting

let client = TailnetClient(backend: InMemoryTailnetBackend())
```

## How it works

TailnetKit keeps Swift API design, the Go runtime, and Tailscale networking in separate layers:

```text
Application
    |
TailnetClient (Swift actor: profiles, state, peers, dialing)
    |
GoTailnetBackend  ──►  TailnetCore.xcframework
                          |
                          C ABI (go build -buildmode=c-archive)
                          |
                          Go tsnet engine
                          |
                          Tailscale control plane, DERP, direct paths, WireGuard
```

Swift owns the public API, concurrency, lifecycle, persistence, and UI state. Go owns `tsnet.Server`, control-plane state, peer discovery, dialing, path selection, and the loopback relay. The two communicate over a small, versioned, hand-written C ABI.

### Why not expose the C ABI directly?

The C ABI over tsnet is an implementation detail, not a good public Swift interface. TailnetKit provides typed models instead of JSON, Swift actors instead of manual queues, `AsyncSequence` state streams, structured errors, configurable persistence, testable backends, and a stable versioned boundary.

## Supported platforms

iOS, iPadOS, and macOS (including Mac Catalyst where practical). The XCFramework ships device, simulator, and macOS slices.

watchOS is not a target as a full embedded node — watch apps should use a companion device or a public authenticated service instead.

## Security

- Tailnet state lives in per-profile directories with configurable file protection.
- Stopping a node and destroying its identity are distinct operations.
- Auth URLs and control-plane secrets are kept out of logs.
- The public API surfaces insecure configuration rather than silently accepting it.

## License

TailnetKit is released under the BSD-3-Clause license; see [LICENSE](LICENSE).

It builds on Tailscale's open-source `tsnet` and the wider Tailscale Go module, along with their transitive dependencies. Their notices are preserved in [NOTICE](NOTICE). Every release records the exact bundled Tailscale and Go versions. TailnetKit is independent, uses no Tailscale branding, and is not affiliated with or endorsed by Tailscale.
