# TailnetKit Migration Plan

## 1. Objective

Extract the reusable embedded-tailnet implementation from the existing iGhost/iGhostty codebase into a standalone public TailnetKit repository.

The final state should be:

```text
iGhost/iGhostty
    |
    | Swift Package dependency
    v
TailnetKit public API
    |
    v
TailnetKitEmbedded
    |
    v
TailnetCore.xcframework
    |
    v
Go tsnet engine
```

iGhost/iGhostty must no longer:

- build or import the gomobile bridge directly
- know the Go package layout
- own the XCFramework
- parse tailnet JSON
- manage `tsnet.Server`
- serialize lifecycle operations manually
- implement generic relay mechanics
- own generic profile storage abstractions

iGhost/iGhostty should continue to own:

- SSH configuration
- terminal sessions
- workspace state
- host presentation
- SSH authentication
- known-host policy
- application navigation
- iGhost/iGhostty-specific persistence
- user-facing terminal and session UX

## 2. Existing implementation inventory

Current relevant assets:

### Build

- `Scripts/build-tailnet-kit.sh`
- `Packages/TailnetKit/Go`
- `Vendor/TailnetCore.xcframework`
- XcodeGen references in the iOS project
- pre-build logic that builds the XCFramework when missing

### Swift bridge adaptation

- `GoTailnetBackend`
- `TailnetBridgeExecutor`
- `GoEventListener`
- `TailnetBootstrap`
- `TailnetEngine`
- `TailnetProfile`
- `TailnetProfileStore`
- `InMemoryTailnetBackend`

### Go implementation

- gomobile `bridge` package
- `tailnet.Engine`
- `tsnet.Server` configuration
- status polling
- login URL emission
- device approval state
- peer discovery
- TCP dialing
- loopback relay
- Tailscale SSH host-key verification

### App integration

- `ConnectionCoordinator`
- `TailnetRelayManager`
- SwiftNIO SSH client
- workspace and host models
- UI for login and approval

## 3. Desired ownership after extraction

| Concern | TailnetKit | iGhost/iGhostty |
|---|---:|---:|
| Go module | Yes | No |
| gomobile build | Yes | No |
| XCFramework | Yes | No |
| Bridge versioning | Yes | No |
| Tailnet lifecycle | Yes | No |
| Peer discovery | Yes | No |
| Loopback relay | Yes | No |
| Generic diagnostics | Yes | No |
| Generic profiles | Yes | App chooses storage |
| SwiftUI status components | Optional | App composes |
| SSH connection orchestration | No | Yes |
| Terminal sessions | No | Yes |
| Workspace persistence | No | Yes |
| SSH host UI | No | Yes |
| Known-host policy | Helper only | Yes |
| App navigation | No | Yes |

## 4. Migration constraints

- Keep the application buildable after every major step.
- Avoid a flag-day repository split.
- Add tests before moving behavior.
- Preserve existing state directories.
- Preserve existing tailnet node identities where possible.
- Preserve profile identifiers.
- Do not force users to reauthenticate unnecessarily.
- Do not change SSH behavior during the extraction.
- Do not optimize the relay until the extraction is stable.

## 5. Step-by-step migration

### Step 1: Freeze current behavior

Add tests around:

- profile JSON encoding
- Go profile decoding
- lifecycle state decoding
- login URL state
- device approval state
- running state
- peer decoding
- relay creation
- relay cleanup
- lazy backend initialization
- in-memory fallback
- SSH host-key lookup

Capture current benchmarks:

- application launch
- first bridge initialization
- first tailnet startup
- idle memory
- XCFramework size
- relay throughput
- SSH interactive latency

### Step 2: Introduce semantic public models internally

Create or normalize:

```text
TailnetProfile
TailnetState
TailnetIdentity
TailnetPeer
TailnetDestination
TailnetRelay
TailnetDiagnostics
TailnetError
```

Ensure application code uses these rather than raw bridge results.

### Step 3: Define the backend protocol

Introduce:

```swift
public protocol TailnetBackend
```

Move all Go-specific calls behind `GoTailnetBackend`.

Ensure `InMemoryTailnetBackend` conforms to the same protocol.

### Step 4: Replace singleton coupling

Current:

```text
TailnetBootstrap -> TailnetEngine.shared
```

Target:

```text
Application composition root
    -> constructs TailnetClient
    -> injects it into environment/services
```

A shared instance may still exist as application composition, but it must not be required by the library.

### Step 5: Convert lifecycle ownership to an actor

Create a `TailnetClient` actor.

Move into it:

- lifecycle sequencing
- selected profile
- backend ownership
- relay registry
- state publication
- cancellation

Keep Go `opMu` as defensive bridge protection.

### Step 6: Version the bridge protocol

Add:

- protocol version in every event
- bridge build metadata
- bundled Tailscale version
- Go toolchain version
- explicit mismatch errors

Update Swift decoding before repository extraction.

### Step 7: Separate SSH-specific code

Move generic code to TailnetKit:

- start and stop
- peers
- relay creation
- diagnostics
- generic identity

Keep in iGhost/iGhostty:

- host models
- SSH username and port selection
- SwiftNIO SSH pipeline
- terminal sessions
- workspace behavior
- reconnection policy

Move Tailscale host-key lookup into optional `TailnetKitSSH` only if it can be expressed independently.

### Step 8: Introduce profile-store abstraction

Replace direct `UserDefaults` ownership with:

```swift
TailnetProfileStore
```

Provide a UserDefaults adapter for compatibility.

iGhost/iGhostty may continue using the adapter initially.

Preserve:

- existing profile IDs
- existing state-directory paths
- existing control URLs
- existing hostnames

### Step 9: Split internal package products

Inside the current repository, create:

```text
TailnetKitCore
TailnetKitEmbedded
TailnetKitRelay
TailnetKitTesting
TailnetKitSSH
TailnetKitUI
```

Make iGhost/iGhostty depend only on product targets.

Do not move repositories yet.

### Step 10: Stabilize the build script

Rename and generalize the script:

```text
Scripts/build-xcframework.sh
```

It should:

- use pinned tool versions
- avoid mutating the module unexpectedly
- build all supported slices
- verify architectures
- record metadata
- output checksums
- support CI
- support local development

Remove assumptions about iGhost/iGhostty paths.

### Step 11: Create the public repository

Create the new repository with:

- package sources
- Go sources
- build scripts
- documentation
- examples
- tests
- license
- notices
- CI

Initially publish it as an alpha.

### Step 12: Move history

Preferred options:

1. Use `git filter-repo` to preserve history for the TailnetKit paths.
2. Import filtered history into the new repository.
3. Add cleanup commits that normalize layout.
4. Retain attribution in the iGhost/iGhostty repository.

If history extraction is too noisy, move with a documented provenance commit.

### Step 13: Establish temporary local dependency

During active migration, use one of:

- Swift package local path
- Git submodule only temporarily
- package branch dependency
- workspace package override

Preferred development mode:

```swift
.package(path: "../TailnetKit")
```

Preferred committed mode:

```swift
.package(
    url: "https://github.com/<owner>/TailnetKit.git",
    exact: "0.1.0-alpha.1"
)
```

### Step 14: Move XCFramework ownership

The public repository becomes responsible for:

- source build
- generated binary
- release artifact
- checksums
- notices

Remove from iGhost/iGhostty:

- `Vendor/TailnetCore.xcframework`
- direct pre-build gomobile scripts
- direct Go toolchain requirements
- direct binary embedding configuration

The Swift package should declare the binary target.

### Step 15: Update iGhost/iGhostty composition

The application should create TailnetKit in one composition root.

Example:

```swift
let profileStore = UserDefaultsTailnetProfileStore(
    suiteName: nil
)

let backend = GoTailnetBackend()

let tailnetClient = TailnetClient(
    backend: backend,
    profileStore: profileStore
)
```

Inject it into:

- connection coordinator
- SwiftUI environment
- diagnostics UI
- host browser

### Step 16: Simplify ConnectionCoordinator

Current responsibility includes tailnet startup and relay handling.

Target responsibility:

```text
Given an SSH host:
- choose direct or tailnet path
- request a TailnetKit endpoint
- configure SwiftNIO SSH
- manage SSH session lifecycle
```

It should not understand Go bridge semantics.

### Step 17: Replace TailnetRelayManager app code

If the manager is generic, move it into `TailnetKitRelay`.

If it is partly SSH-specific, split it:

```text
TailnetKitRelay:
- create and own relays
- relay cleanup
- endpoint leases

iGhost/iGhostty:
- choose SSH destination
- associate relay with workspace/session
```

### Step 18: Preserve user state

Before changing state paths:

- map existing profile IDs
- keep existing Application Support directories
- add migration tests
- verify that `tsnet` accepts the moved path
- avoid copying node state through insecure temporary locations

If repository extraction does not change runtime paths, no user migration should be required.

### Step 19: Remove legacy code

After the external package is stable, remove:

- duplicate Swift models
- direct bridge imports
- old build scripts
- old XCFramework
- obsolete bootstrap logic
- direct JSON parsing
- redundant queue serialization
- generic relay code now owned by TailnetKit

### Step 20: Add compatibility tests in iGhost/iGhostty

Test:

- existing user profile starts
- existing node identity remains valid
- interactive login still works
- device approval appears
- peer list is unchanged
- SSH session opens through relay
- host-key verification still works
- stop and restart work
- app relaunch preserves state

## 6. Final iGhost/iGhostty boundary

The intended application code should resemble:

```swift
import TailnetKitCore
import TailnetKitEmbedded
import TailnetKitRelay
import TailnetKitSSH

final class ConnectionCoordinator {
    private let tailnet: TailnetClient
    private let sshConnector: SSHConnector

    init(
        tailnet: TailnetClient,
        sshConnector: SSHConnector
    ) {
        self.tailnet = tailnet
        self.sshConnector = sshConnector
    }

    func connect(to host: SSHHost) async throws -> SSHSession {
        let endpoint: NetworkEndpoint

        switch host.transport {
        case .direct:
            endpoint = .remote(host.hostname, host.port)

        case .embeddedTailnet:
            try await tailnet.ensureRunning()

            let relay = try await tailnet.openLoopbackRelay(
                to: TailnetDestination(
                    host: host.hostname,
                    port: host.port
                )
            )

            endpoint = .local(relay.host, relay.port)
        }

        return try await sshConnector.connect(
            endpoint: endpoint,
            configuration: host.sshConfiguration
        )
    }
}
```

The coordinator knows that TailnetKit can produce an endpoint. It does not know how.

## 7. Public-repository release sequence

### `0.1.0-alpha.1`

- Source package
- embedded backend
- typed lifecycle
- peer discovery
- relay
- in-memory testing backend
- iGhost/iGhostty as primary consumer

### `0.1.0-alpha.2`

- example applications
- stronger diagnostics
- bridge version checks
- state migration tests

### `0.2.0`

- binary SwiftPM release
- reproducible builds
- checksums and provenance
- documentation cleanup

### `0.3.0`

- second real consumer
- API revisions based on dogfooding
- optional SwiftUI module

### `1.0.0`

Only after:

- at least two production consumers
- one or more upstream Tailscale upgrade cycles
- stable state migration
- stable bridge protocol
- release automation
- documented compatibility policy

## 8. Rollback strategy

During migration:

- keep the old implementation on a temporary branch
- preserve old state paths
- retain a feature flag for old versus package backend where practical
- make package versions exact rather than floating
- do not delete old build artifacts until the package release is verified
- keep integration tests capable of testing both paths temporarily

A rollback should require changing the package selection, not recovering user identities.

## 9. Completion criteria

The migration is complete when:

- TailnetKit is in a separate public repository
- iGhost/iGhostty consumes it through Swift Package Manager
- iGhost/iGhostty contains no Go module
- iGhost/iGhostty contains no bundled Tailnet XCFramework
- iGhost/iGhostty imports no gomobile-generated symbols
- TailnetKit builds reproducibly
- TailnetKit owns the bridge and relay
- iGhost/iGhostty owns only SSH and application behavior
- existing users do not need to rejoin the tailnet
- integration tests verify the clean boundary
