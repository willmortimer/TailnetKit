# TailnetKit Architecture

## 1. Architectural overview

TailnetKit uses a layered architecture that keeps application code, Swift API design, gomobile adaptation, and Tailscale networking behavior separate.

```text
+------------------------------------------------------+
| Consuming application                               |
| iGhost/iGhostty, observability app, media client    |
+---------------------------+--------------------------+
                            |
                            v
+------------------------------------------------------+
| TailnetKit public Swift API                          |
| TailnetClient, profiles, state, peers, diagnostics  |
+-------------+----------------+-----------------------+
              |                |
              v                v
+----------------------+   +---------------------------+
| Pure Swift backends  |   | Embedded Go backend      |
| system, mock, test   |   | GoTailnetBackend         |
+----------------------+   +-------------+-------------+
                                          |
                                          v
                            +---------------------------+
                            | TailnetCore.xcframework   |
                            | gomobile-generated API    |
                            +-------------+-------------+
                                          |
                                          v
                            +---------------------------+
                            | Go bridge                 |
                            | versioned thin facade     |
                            +-------------+-------------+
                                          |
                                          v
                            +---------------------------+
                            | Go tailnet engine         |
                            | tsnet.Server              |
                            +-------------+-------------+
                                          |
                                          v
                            +---------------------------+
                            | Tailscale network         |
                            | direct paths, DERP, ctrl  |
                            +---------------------------+
```

## 2. Repository layout

Proposed public repository:

```text
TailnetKit/
├── Package.swift
├── README.md
├── DESIGN.md
├── ARCHITECTURE.md
├── ROADMAP.md
├── MIGRATION.md
├── LICENSE
├── NOTICE
├── SECURITY.md
├── CONTRIBUTING.md
├── CHANGELOG.md
├── Sources/
│   ├── TailnetKitCore/
│   ├── TailnetKitEmbedded/
│   ├── TailnetKitRelay/
│   ├── TailnetKitUI/
│   ├── TailnetKitSSH/
│   └── TailnetKitTesting/
├── Tests/
│   ├── TailnetKitCoreTests/
│   ├── TailnetKitEmbeddedTests/
│   ├── TailnetKitRelayTests/
│   └── TailnetKitIntegrationTests/
├── Go/
│   ├── go.mod
│   ├── go.sum
│   ├── bridge/
│   ├── tailnet/
│   └── internal/
├── Vendor/
│   └── TailnetCore.xcframework
├── Scripts/
│   ├── build-xcframework.sh
│   ├── verify-xcframework.sh
│   ├── update-tailscale.sh
│   ├── generate-notices.sh
│   └── smoke-test.sh
├── Examples/
│   ├── PeerBrowser/
│   ├── TCPProbe/
│   ├── HTTPClient/
│   └── SSHClient/
└── .github/
    └── workflows/
```

## 3. Package dependency graph

```text
TailnetKitCore
    ^
    |
    +-- TailnetKitTesting
    +-- TailnetKitUI
    +-- TailnetKitRelay
    +-- TailnetKitSSH
    +-- TailnetKitEmbedded --> TailnetCore binary target
```

Rules:

- Core has no binary dependency.
- UI depends only on Core.
- Testing depends only on Core.
- SSH depends on Core and optionally Relay.
- Embedded depends on Core and the XCFramework.
- Application-specific code must not enter Core.

## 4. Swift runtime architecture

### TailnetClient actor

`TailnetClient` is the application-facing runtime owner.

Responsibilities:

- Hold the selected backend
- Hold the active profile
- Serialize lifecycle changes
- Publish state and events
- Track relays
- Enforce cancellation
- Coordinate persistence
- Expose diagnostics

It must not know about gomobile symbols.

### TailnetBackend

The backend protocol isolates the implementation.

Initial implementations:

```text
GoTailnetBackend
InMemoryTailnetBackend
```

Future implementations:

```text
SystemTailnetBackend
ScriptedTailnetBackend
NativeStreamGoTailnetBackend
SwiftNativeTailnetBackend
```

### Profile store

Profile storage is injected.

The library should ship reference adapters but must not force an application database.

## 5. Go runtime architecture

### bridge package

The bridge is the only package exported through gomobile.

It should:

- use gomobile-compatible types
- expose a narrow API
- validate inputs
- serialize versioned events
- avoid leaking internal Go types
- protect control operations
- delegate to the engine

It should not:

- own application persistence
- implement UI policy
- contain SSH-specific session logic
- expose unversioned arbitrary JSON
- accept raw application callbacks on arbitrary goroutines without adaptation

### tailnet engine

The engine owns:

- `tsnet.Server`
- startup
- shutdown
- local client
- status polling or subscription
- peer queries
- relay creation
- identity destruction
- diagnostics
- Tailscale SSH host-key metadata

### relay manager

The relay manager owns:

- local listeners
- mapping relay IDs to destinations
- accept loops
- byte pumps
- cancellation
- cleanup
- counters

## 6. Lifecycle sequence

```text
Application
    |
    | configure(profile)
    v
TailnetClient actor
    |
    | backend.configure
    v
GoTailnetBackend
    |
    | encoded profile
    v
Bridge
    |
    | create tsnet.Server
    v
Engine
    |
    | status changes
    v
Bridge event callback
    |
    | versioned event JSON
    v
GoTailnetBackend decoder
    |
    | TailnetState
    v
TailnetClient state stream
    |
    v
SwiftUI/application
```

## 7. Authentication sequence

```text
start()
  |
  v
tsnet starts without blocking on interactive Up()
  |
  v
LocalClient status indicates login required
  |
  v
Go emits needs_login(loginURL)
  |
  v
Swift emits TailnetState.needsLogin
  |
  v
Application opens URL
  |
  v
User authenticates
  |
  v
status becomes approval-required or running
```

The library must not assume that it may present UI.

## 8. Relay sequence

```text
Application protocol library
    |
    | connects to 127.0.0.1:ephemeral
    v
Go relay listener
    |
    | tsnet.Server.Dial(destination)
    v
Tailnet path
    |
    v
Remote service
```

The local endpoint is a compatibility adapter.

A future direct stream architecture may bypass it.

## 9. Error architecture

Errors should be divided into stable semantic categories:

```swift
public enum TailnetError: Error, Sendable {
    case invalidProfile
    case bridgeUnavailable
    case bridgeVersionMismatch
    case stateDirectoryUnavailable
    case authenticationRequired
    case deviceApprovalRequired
    case controlPlaneUnavailable
    case destinationUnreachable
    case relayFailed
    case cancelled
    case unsupportedPlatform
    case upstream(UpstreamTailnetError)
}
```

Upstream details should be preserved for diagnostics without forcing consumers to parse strings.

## 10. Build architecture

### Source build

`Scripts/build-xcframework.sh` should:

1. Verify required tool versions.
2. Resolve the pinned Tailscale revision.
3. Run `go mod tidy` only in a validation mode or ensure the tree remains clean.
4. Build device, simulator, and macOS slices.
5. Produce `TailnetCore.xcframework`.
6. Strip or package debug symbols appropriately.
7. Generate checksums.
8. Record build metadata.
9. Run symbol and architecture validation.
10. Fail if generated files differ unexpectedly.

### Binary distribution

A release pipeline should:

- Build from a clean tagged commit
- Produce a zipped XCFramework
- Produce a SwiftPM checksum
- Generate an SBOM
- Generate dependency notices
- Sign release artifacts
- Attach provenance
- Publish a compatibility manifest

## 11. Versioning architecture

TailnetKit has several independently relevant versions:

```text
TailnetKit API version
Bridge protocol version
Bundled Tailscale version
Go toolchain version
gomobile version
XCFramework artifact version
```

Every release should publish all of them.

Compatibility should be documented as:

```text
TailnetKit 0.4.0
- bridge protocol 2
- Tailscale vX.Y.Z
- Go X.Y
- Swift 6
- iOS 17+
- macOS 14+
```

## 12. CI architecture

Required workflows:

### Swift validation

- build all Swift products
- run unit tests
- run concurrency checks
- run formatting and linting
- build examples

### Go validation

- test bridge and engine
- run race tests where possible
- verify pinned dependencies
- ensure clean module state

### XCFramework build

- build all slices
- verify module import
- verify binary architectures
- build a sample consuming app
- record artifact size

### Integration tests

- use a disposable control environment where practical
- test login-required state
- test running state
- test peer discovery
- test relay TCP echo
- test cancellation
- test corrupted state recovery
- test network transition behavior manually or in dedicated CI infrastructure

## 13. Security architecture

### Trust boundaries

```text
Application UI
    |
Swift TailnetKit
    |
gomobile ABI boundary
    |
Go runtime
    |
Tailscale control plane and peers
```

### Sensitive assets

- tailnet node state
- auth keys
- login URLs
- device identity
- private service destinations
- diagnostics
- optional application-level Secure Enclave keys

### Security controls

- per-profile directories
- configurable file protection
- no payload logging
- Keychain credential adapters
- explicit identity deletion
- signed/checksummed binaries
- dependency notices
- build provenance
- redacted diagnostics
- least-privilege app-specific tailnet grants

## 14. Apple integration architecture

### Network path

`NWPathMonitor` may enrich diagnostics and workload policy.

It must not duplicate Tailscale path selection.

### Local authentication

Face ID and LocalAuthentication may protect:

- opening the app
- loading credentials
- revealing private services
- executing sensitive app actions

### Secure Enclave

A separate application identity may bind:

- the Apple device
- the local user presence check
- a private service session

This identity supplements rather than replaces Tailscale node identity.

### tvOS

tvOS support should focus on:

- application-scoped private service access
- media HTTP proxying
- AVPlayer compatibility
- constrained memory and lifecycle behavior

## 15. Optional Swift-native tsnet-compatible architecture

A future research implementation should target only application-scoped dialing.

Possible layers:

```text
Swift control client
Swift node identity
Swift netmap model
Swift endpoint discovery
Swift STUN
Swift DERP client
Swift WireGuard data plane
Swift peer path manager
Swift outbound TCP/UDP interface
```

It should deliberately omit system-wide VPN responsibilities until the application-scoped implementation is mature.

This future backend should conform to the same `TailnetBackend` interface, preserving application compatibility.
