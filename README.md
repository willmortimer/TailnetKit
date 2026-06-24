# TailnetKit

TailnetKit is a Swift-native developer experience for embedding an application-scoped tailnet node into Apple-platform applications.

It wraps Tailscale's Go `tsnet` implementation behind a typed Swift concurrency API, packages the Go runtime as an XCFramework, and provides reusable building blocks for authentication, lifecycle management, peer discovery, private-network dialing, loopback relays, diagnostics, SwiftUI integration, and testing.

TailnetKit is intended for applications that need direct access to private tailnet services without requiring the user to route the entire device through the installed Tailscale VPN.

Examples include:

- SSH and terminal clients
- Internal administration tools
- Native observability clients
- Private API clients
- Database and infrastructure tools
- Media clients for private Jellyfin or similar servers
- Enterprise applications with app-specific tailnet identities
- Developer tools that need secure access to private services

TailnetKit is an independent project built on Tailscale's open-source code. It is not an official Tailscale SDK.

## Project status

TailnetKit begins as an extraction of the embedded-tailnet implementation currently used by iGhost/iGhostty.

The existing implementation already includes:

- A Go `tsnet` engine
- A thin gomobile bridge
- `TailnetCore.xcframework`
- Lazy bridge initialization
- Profile-specific state directories
- Nonblocking interactive login handling
- Device-approval state handling
- Peer discovery
- Tailnet TCP dialing
- A local loopback relay for existing Swift networking libraries
- Swift-side backend abstractions
- SwiftUI-facing lifecycle state
- In-memory fallback and testing support
- SSH host-key verification support through Tailscale metadata

The extraction goal is not to publish application-specific SSH code. It is to publish the reusable embedded-tailnet transport and Apple-platform integration layer behind a stable public API.

## Core design

TailnetKit separates the product into layers:

```text
Application
    |
    v
TailnetKit Swift API
    |
    +-- TailnetKitCore
    +-- TailnetKitEmbedded
    +-- TailnetKitRelay
    +-- TailnetKitUI
    +-- TailnetKitTesting
    |
    v
TailnetCore.xcframework
    |
    v
gomobile bridge
    |
    v
Go tsnet engine
    |
    v
Tailscale control plane, DERP, direct peer paths, WireGuard
```

Swift owns:

- Public API design
- Application lifecycle integration
- Profiles and persistence abstractions
- Swift concurrency
- UI state
- Keychain and local security integration
- Diagnostics presentation
- App-specific protocol stacks such as SSH
- Optional Apple-framework integrations

Go owns:

- `tsnet.Server`
- Tailnet startup and control-plane state
- Peer discovery
- Tailnet dialing
- Direct and DERP path selection
- Tailscale protocol compatibility
- Loopback byte relays
- Tailscale-specific host-key lookup
- Low-level transport behavior

## Package products

### TailnetKitCore

Pure Swift models and protocols with no Go binary dependency.

Contains:

- `TailnetClient`
- `TailnetBackend`
- `TailnetProfile`
- `TailnetState`
- `TailnetEvent`
- `TailnetPeer`
- `TailnetDestination`
- `TailnetConnectionPolicy`
- Profile-store protocols
- Diagnostics models
- Error types

### TailnetKitEmbedded

The production embedded-tailnet backend.

Contains:

- `GoTailnetBackend`
- gomobile adaptation
- bridge protocol version checking
- event decoding
- state-directory handling
- Go runtime lifecycle
- Tailscale-specific diagnostics

Depends on `TailnetCore.xcframework`.

### TailnetKitRelay

Compatibility transport for libraries that require a conventional TCP endpoint.

Contains:

- Loopback relay creation
- Relay leases
- Cancellation
- Half-close handling
- Connection accounting
- Idle timeout support
- Optional HTTP proxy support later

### TailnetKitUI

Optional SwiftUI components.

Contains:

- Login state views
- Device-approval state
- Connection status controls
- Peer picker
- Diagnostics screen
- Tailnet profile editor
- Error recovery UI

### TailnetKitTesting

Testing and preview support.

Contains:

- `InMemoryTailnetBackend`
- Scripted lifecycle transitions
- Synthetic peers
- Failure injection
- Deterministic clocks
- Relay stubs
- SwiftUI preview fixtures

### TailnetKitSSH

Optional SSH-specific helpers.

Contains:

- Tailscale SSH host-key lookup
- Host identity normalization
- SwiftNIO SSH integration helpers
- Known-host verification adapters

This module is intentionally separate from the core package.

## Example

```swift
import TailnetKitEmbedded

let client = TailnetClient(
    backend: .embedded(),
    profile: TailnetProfile(
        id: UUID(),
        displayName: "Personal Tailnet",
        hostname: "my-ios-app",
        controlURL: nil,
        stateDirectory: .applicationSupport("tailnet/default")
    )
)

Task {
    for await state in client.states {
        switch state {
        case .needsLogin(let loginURL):
            print("Open:", loginURL)

        case .needsDeviceApproval:
            print("Approve this device in the tailnet admin console")

        case .running(let identity):
            print("Connected as", identity.hostname)

        case .failed(let error):
            print("Tailnet error:", error)

        default:
            break
        }
    }
}

try await client.start()

let relay = try await client.openLoopbackRelay(
    to: TailnetDestination(host: "server.example.ts.net", port: 22)
)

print("Connect the existing TCP client to \(relay.host):\(relay.port)")
```

## Why not expose gomobile directly?

gomobile-generated APIs are an implementation detail rather than an appropriate public Swift interface.

TailnetKit provides:

- Typed models instead of JSON strings
- Swift actors instead of manual queue management
- `AsyncSequence` state streams
- Structured errors
- Configurable persistence
- Testable backends
- Stable versioned boundaries
- SwiftUI integration
- Apple-platform lifecycle behavior
- A path toward non-loopback native streams

## System Tailscale versus embedded tailnet

TailnetKit supports two conceptual operating modes.

### System Tailscale mode

The application uses ordinary Apple networking while the installed Tailscale application provides device-level routing.

Advantages:

- Lowest complexity
- Small application binary
- Tailscale owns VPN lifecycle
- No second application-specific tailnet device
- Preferred default when available

### Embedded mode

The application creates its own application-scoped tailnet node through `tsnet`.

Advantages:

- Does not require the system Tailscale VPN to be active
- Does not interfere with another system VPN
- Gives the application an independent tailnet identity
- Supports app-specific ACLs, grants, and capabilities
- Limits the application to explicitly authorized services
- Can provide a clean private transport inside one app

TailnetKit should eventually expose both through a common interface, while keeping the embedded binary optional.

## Supported platforms

Initial targets:

- iOS
- iPadOS
- macOS
- Mac Catalyst where practical

Planned exploratory target:

- tvOS, especially for private media clients and internal-display applications

Not a core target:

- watchOS as a full embedded tailnet node

Watch applications should normally use a companion iPhone, a gateway, or a public authenticated service rather than running the complete data plane.

## Security principles

- Long-lived credentials must not be exposed through public logs.
- Tailnet state must live in per-profile directories.
- File protection must be configurable.
- Stopping a node and deleting its identity must be distinct operations.
- Auth URLs and control-plane secrets must be redacted.
- Durable credentials should use Keychain-backed storage.
- Secure Enclave keys may be used for application-level device identity.
- Bulk telemetry or payload data must not cross the Go/Swift boundary as JSON.
- The public API must make insecure configuration visible rather than silently accepting it.

## Distribution

TailnetKit should publish:

- Swift Package Manager products
- Prebuilt signed/checksummed XCFramework releases
- Reproducible source build instructions
- Exact Go, gomobile, and Tailscale versions
- Software bill of materials
- License notices
- Release provenance
- Example applications
- Compatibility tables

## Repository goals

The public repository should make this workflow possible:

```text
Add Swift package
    |
Select system or embedded backend
    |
Create a profile
    |
Start the client
    |
Handle login state
    |
Dial a private service
```

A consuming developer should not need to understand gomobile, `tsnet.Server`, Go runtime behavior, or the Tailscale control protocol.

## Non-goals

TailnetKit is not initially:

- A replacement for the Tailscale iOS application
- A complete Swift-native Tailscale implementation
- A VPN client
- A generic userspace network stack
- A full SSH client
- A clone of Tailscale's control plane
- A promise of compatibility with every undocumented `tsnet` behavior
- A watchOS networking runtime

## License and naming

The final project license must be selected after auditing all bundled dependencies and redistribution obligations.

The repository should:

- Preserve all required Tailscale and dependency notices
- Avoid official Tailscale branding
- State clearly that it is independent
- Publish the exact upstream revision included in every release
- Avoid calling itself the official Swift SDK
