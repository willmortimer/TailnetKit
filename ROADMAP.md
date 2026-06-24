# TailnetKit Roadmap

## Guiding principle

The project should first extract and stabilize what already works in iGhost/iGhostty.

It should not begin by rewriting networking internals, adding a packet tunnel, or pursuing every Apple-platform moonshot.

The roadmap prioritizes:

1. clean extraction
2. stable API
3. reproducible distribution
4. real second-application dogfooding
5. performance work based on profiling
6. advanced Apple integration

## Phase 0: Extraction preparation

### Goals

- Identify reusable versus application-specific code
- Freeze the current behavior
- Add tests before moving files
- Define the initial public package boundary

### Work

- Document all current bridge operations
- Record current lifecycle transitions
- Add tests for profile encoding
- Add tests for state decoding
- Add tests for peer decoding
- Add tests for relay lifecycle
- Add tests for lazy backend construction
- Add tests for fallback behavior
- Measure current binary size, launch cost, memory, and relay performance
- Record exact Go, gomobile, and Tailscale versions
- Audit licenses

### Exit criteria

- Existing iGhost/iGhostty behavior is covered by tests
- Public versus private APIs are identified
- Current upstream revisions are pinned

## Phase 1: Internal package cleanup inside iGhost/iGhostty

### Goals

- Make TailnetKit logically independent before moving repositories
- Remove direct application imports from reusable code
- Introduce stable protocols

### Work

- Create `TailnetKitCore`
- Create `TailnetKitEmbedded`
- Create `TailnetKitRelay`
- Create `TailnetKitTesting`
- Move SSH-specific behavior into `TailnetKitSSH` or the app
- Replace singleton-only access with injectable `TailnetClient`
- Introduce `TailnetProfileStore`
- Replace public JSON methods with typed models
- Add bridge protocol versioning
- Convert lifecycle ownership to an actor
- Expose `AsyncStream` state and events
- Make file protection configurable
- Distinguish stop from identity deletion

### Exit criteria

- iGhost/iGhostty consumes only the new internal package API
- Application code no longer imports gomobile-generated symbols
- The embedded implementation can be replaced by an in-memory backend in tests

## Phase 2: Public repository extraction

### Goals

- Create the standalone repository
- Preserve history where useful
- Keep iGhost/iGhostty building throughout the transition

### Work

- Create the public repository structure
- Move pure Swift modules
- Move Go modules and bridge code
- Move build scripts
- Add license and notice files
- Add security and contribution policy
- Add reproducible build documentation
- Add CI
- Add example applications
- Publish an initial source-only pre-release tag
- Point iGhost/iGhostty at a temporary Git dependency or local package override

### Exit criteria

- Fresh clone can build the package
- Fresh clone can build the XCFramework
- Example app can authenticate and list peers
- iGhost/iGhostty builds using the external repository

## Phase 3: First public alpha

### Goals

- Validate the package with external-style consumption
- Keep API expectations narrow

### Included

- iOS and macOS
- Embedded backend
- Interactive login
- Device approval state
- Peer discovery
- Loopback TCP relay
- Typed lifecycle
- Typed diagnostics
- In-memory testing backend
- Minimal SwiftUI components
- SSH helper module if ready

### Excluded

- Stable 1.0 API promise
- System Tailscale backend
- Direct stream bridge
- tvOS
- HTTP proxy
- UDP
- packet tunnel
- Swift-native networking implementation

### Exit criteria

- At least two real applications consume the package
- No application imports internal bridge symbols
- Integration tests cover the primary lifecycle
- Public documentation matches behavior

## Phase 4: Distribution hardening

### Goals

- Make adoption easy and trustworthy

### Work

- Publish prebuilt XCFramework releases
- Publish SwiftPM checksums
- Add artifact signatures and provenance
- Generate SBOMs
- Publish compatibility matrix
- Add binary-size reporting
- Add release automation
- Add upgrade notes for bundled Tailscale revisions
- Add sample CI for consumers
- Add diagnostics export
- Add state-migration framework

### Exit criteria

- A consumer can add one Swift package dependency and build
- A consumer can independently rebuild the binary
- Every release identifies all upstream toolchain versions

## Phase 5: System Tailscale backend

### Goals

- Support the preferred installed-Tailscale path
- Avoid requiring the embedded binary for every app

### Work

- Add `SystemTailnetBackend`
- Use normal Network.framework or URLSession paths
- Add tailnet-reachability diagnostics
- Add MagicDNS resolution hints
- Add user-facing recovery hooks
- Add Tailscale app deep-link support where feasible
- Keep the package useful without the XCFramework

### Exit criteria

- Applications can switch between system and embedded modes
- Pure system-mode consumers do not link the Go binary

## Phase 6: HTTP and media transport

### Goals

- Expand beyond SSH and generic TCP
- Support observability and media applications

### Work

- Add local HTTP reverse proxy
- Support authentication headers
- Support TLS verification
- Support range requests
- Support cancellation and seeking
- Support connection reuse
- Add URL mapping
- Add metrics and bounded buffering
- Prototype AVPlayer integration
- Add tvOS build support

### Exit criteria

- Example app streams a private media object over the embedded tailnet
- Example app queries a private HTTP API
- HTTP behavior is covered by conformance tests

## Phase 7: App capabilities and zero-config onboarding

### Goals

- Let tailnet policy configure applications securely

### Work

- Add typed app-capability decoding
- Add service manifest model
- Add capability-based endpoint discovery
- Add application policy model
- Add automatic profile suggestions
- Add diagnostics for malformed or unauthorized capabilities
- Build an example internal-tool application

### Exit criteria

- App joins tailnet and discovers an authorized service without manual endpoint entry
- Capability data is validated and versioned

## Phase 8: Secure Enclave application identity

### Goals

- Add Apple-native device-bound application sessions

### Work

- Generate per-device Secure Enclave keys
- Add Face ID-gated signing
- Define enrollment protocol
- Define gateway verification
- Add device revocation
- Add short-lived application sessions
- Add recovery and re-enrollment
- Keep Tailscale node identity separate

### Exit criteria

- A private service can verify both tailnet source identity and app-device identity
- Sensitive actions can require user presence

## Phase 9: Native stream bridge

### Goals

- Remove loopback overhead for clients that can use a direct stream abstraction

### Work

- Design opaque connection handles
- Design bounded bidirectional buffers
- Implement backpressure
- Implement cancellation
- Implement half-close
- Add Swift AsyncSequence adapter
- Add SwiftNIO Channel adapter
- Benchmark against loopback relay
- Preserve relay compatibility mode

### Exit criteria

- Measurable improvement for high-throughput or high-connection-count workloads
- No regression in correctness
- SSH and HTTP examples can optionally use the native stream path

## Phase 10: Advanced Apple-platform integrations

Candidate work:

- tvOS production support
- AVPlayer transport helpers
- Mac/iPhone Handoff metadata
- nearby profile enrollment
- QUIC application gateway protocol
- path-aware workload policies
- service browser
- compact peer indexes
- direct-versus-DERP telemetry
- application dashboards and diagnostics

These remain optional and should be prioritized by real users.

## Research track: Swift-native tsnet-compatible backend

This track is separate from the main release roadmap.

### Scope

Application-scoped tailnet node only:

- join control plane
- manage node identity
- consume netmaps
- discover endpoints
- use STUN
- connect through DERP
- establish WireGuard peer paths
- expose outbound TCP/UDP

### Deliberate omissions

- whole-device VPN
- packet tunnel
- subnet router
- exit node
- full DNS integration
- complete Tailscale client feature parity

### Milestones

1. Parse control-plane state into a Swift netmap model.
2. Authenticate an application-scoped node.
3. Connect to a DERP region.
4. Exchange encrypted packets with one peer.
5. Establish a direct path.
6. Expose one outbound TCP connection.
7. Conform to `TailnetBackend`.
8. Compare lifecycle, memory, and path behavior with Go `tsnet`.

### Rule

This research track must not block the practical TailnetKit roadmap.

## Version targets

### 0.1

Internal extraction and typed API.

### 0.2

Public repository alpha with embedded backend.

### 0.3

Reproducible XCFramework distribution and examples.

### 0.4

System backend and stronger diagnostics.

### 0.5

HTTP proxy and initial tvOS support.

### 0.6

App capabilities and service discovery.

### 0.7

Secure Enclave application identity.

### 0.8

Native stream prototype.

### 1.0

Stable public API after multiple real consumers and at least one upstream Tailscale upgrade cycle.
