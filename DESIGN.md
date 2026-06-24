# TailnetKit Design

## 1. Product definition

TailnetKit is a reusable Apple-platform SDK that turns Tailscale's Go `tsnet` library into a native-feeling Swift API.

Its product value is not merely packaging a Go binary. Its value is the combination of:

- A stable Swift interface
- A native lifecycle state machine
- Typed peer and identity models
- Swift concurrency
- SwiftUI integration
- Application-scoped tailnet identities
- Existing-network-library compatibility
- Security-conscious state and credential handling
- Testing support
- Optional system-Tailscale fallback
- A roadmap toward higher-performance native stream bridges

The library should feel like an Apple networking framework even though the initial data plane remains implemented by Tailscale's Go code.

## 2. Design goals

### 2.1 Make embedded tailnets boring to consume

The consumer should not manage:

- gomobile bindings
- Go runtime initialization
- bridge callbacks
- JSON decoding
- polling loops
- state-directory conventions
- operation serialization
- loopback relay cleanup
- Tailscale-specific lifecycle edge cases

### 2.2 Keep application code independent from implementation details

Applications should depend on public protocols and typed models.

The embedded Go implementation must be replaceable by:

- an in-memory backend
- a system-Tailscale backend
- a future native stream backend
- a future Swift-native `tsnet`-compatible implementation
- application-specific proxy backends

### 2.3 Preserve upstream protocol compatibility

The initial implementation deliberately delegates the hard networking problem to upstream `tsnet`.

TailnetKit should not duplicate:

- WireGuard
- DERP
- NAT traversal
- endpoint discovery
- control-plane protocol behavior
- key rotation
- peer path selection
- roaming logic

### 2.4 Support existing Swift networking libraries

Many Swift libraries require a normal host and port.

The loopback relay is therefore a first-class compatibility feature, not an embarrassing temporary hack.

### 2.5 Allow deeper integration later

The design must permit:

- a zero- or low-copy Swift/Go stream bridge
- a custom SwiftNIO channel
- a local HTTP proxy
- AVPlayer-compatible media transport
- app-capability-based service discovery
- Secure Enclave-bound application sessions
- tvOS support
- a packet-tunnel product in a separate module

## 3. User stories

### SSH client

An SSH application creates an embedded tailnet profile, waits for login, discovers peers, opens a loopback relay to port 22, and connects through SwiftNIO SSH.

### Observability client

A Grafana/LGTM application joins a tailnet as an app-specific node, receives configured service endpoints through app capabilities, and queries private Grafana, Loki, Tempo, and Prometheus services.

### Internal enterprise app

An organization distributes an app whose tailnet identity can reach only a small set of internal services. No device-wide VPN is required.

### Private media client

A tvOS or iOS Jellyfin client uses a local HTTP proxy over `tsnet` and provides a normal URL to AVPlayer, including range request support.

### Developer tool

A database or API client discovers peers tagged for development and creates temporary relays for existing protocol libraries.

## 4. Public API principles

### 4.1 Swift-first

Public types should use:

- `async`/`await`
- actors
- `AsyncSequence`
- `Sendable`
- structured errors
- value types
- Foundation only where useful

### 4.2 Typed boundaries

The Go bridge may use JSON internally, but JSON must not leak into the public API.

Bad:

```swift
func peersJSON() async throws -> String
```

Good:

```swift
func peers() async throws -> [TailnetPeer]
```

### 4.3 Stable semantic API

The public API should describe capabilities, not upstream implementation details.

Prefer:

```swift
func start() async throws
func stop() async
func destroyIdentity() async throws
func peers() async throws -> [TailnetPeer]
func openLoopbackRelay(to:) async throws -> TailnetRelay
```

Avoid:

```swift
func callTsnetUp()
func localClientStatusJSON()
func invokeBridgeDialTCP()
```

### 4.4 Explicit lifecycle

The lifecycle state machine should be authoritative:

```swift
public enum TailnetState: Sendable, Equatable {
    case stopped
    case starting
    case needsLogin(URL)
    case needsDeviceApproval
    case running(TailnetIdentity)
    case stopping
    case failed(TailnetError)
}
```

Transitions should be validated and observable.

### 4.5 Explicit security state

The API should distinguish:

- stopped
- logged out
- identity destroyed
- credential missing
- device approval required
- control-plane unreachable
- state directory unavailable before first unlock

## 5. Core domain model

### TailnetProfile

Represents a configured embedded identity.

Fields:

- Stable identifier
- Display name
- Hostname
- Optional control URL
- State storage descriptor
- Optional connection policy
- Optional diagnostics policy
- Optional file-protection policy

The profile model must remain independent of `UserDefaults`.

### TailnetIdentity

Represents the current joined node:

- Hostname
- Tailnet DNS name
- Assigned IP addresses
- User or node identifiers when available
- Control server
- Login and key-expiry metadata when available

### TailnetPeer

Represents a peer:

- Stable peer identifier
- Hostname
- DNS name
- Addresses
- Online state
- Operating system
- Tags
- Capabilities
- Path metadata where available

### TailnetDestination

Represents a network target:

- Hostname or IP address
- Port
- Optional protocol metadata
- Optional service identifier

### TailnetRelay

Represents a local compatibility endpoint:

- Host
- Port
- Destination
- Creation time
- Current state
- Connection count
- Cancellation handle

## 6. Backend design

```swift
public protocol TailnetBackend: Sendable {
    var states: AsyncStream<TailnetState> { get }
    var events: AsyncStream<TailnetEvent> { get }

    func configure(profile: TailnetProfile) async throws
    func start() async throws
    func stop() async
    func destroyIdentity() async throws

    func currentState() async -> TailnetState
    func peers() async throws -> [TailnetPeer]
    func diagnostics() async throws -> TailnetDiagnostics

    func openLoopbackRelay(
        to destination: TailnetDestination
    ) async throws -> TailnetRelay
}
```

The initial backends are:

- `GoTailnetBackend`
- `InMemoryTailnetBackend`

Planned:

- `SystemTailnetBackend`
- `NativeStreamGoTailnetBackend`
- `ScriptedTailnetBackend`

## 7. Bridge design

### 7.1 Internal protocol

The gomobile bridge remains intentionally thin.

It should expose operations such as:

- create bridge
- configure profile
- start
- stop
- destroy state
- read status
- read peers
- open relay
- close relay
- retrieve host-key metadata
- retrieve diagnostics

### 7.2 Versioning

Every message crossing the bridge must include a protocol version.

Example:

```json
{
  "protocolVersion": 1,
  "event": "running",
  "payload": {
    "hostname": "ighost",
    "addresses": ["100.64.0.10"]
  }
}
```

The Swift wrapper must reject incompatible bridge versions with a clear error.

### 7.3 Control and data separation

Control plane:

```text
Go structs -> versioned JSON -> Swift Codable
```

Data plane:

```text
Go net.Conn -> relay or native buffer bridge -> Swift client
```

Bulk bytes must never be encoded as JSON or strings.

## 8. Concurrency design

### Swift

`TailnetClient` should be an actor that owns:

- lifecycle sequencing
- active profile
- backend
- relay registry
- cancellation
- state stream publication

### Go

The bridge may retain an operation mutex for lifecycle and control safety.

Raw connection I/O must remain concurrent.

### Rules

- Start is idempotent or returns a defined state error.
- Stop during start must cancel or wait deterministically.
- Relay cancellation must propagate to both sides.
- State emissions must be ordered.
- Slow event consumers must not block the Go engine.
- Diagnostic streams should be buffered and coalesced.

## 9. Persistence design

Profile persistence is provided through a protocol:

```swift
public protocol TailnetProfileStore: Sendable {
    func loadProfiles() async throws -> [TailnetProfile]
    func saveProfiles(_ profiles: [TailnetProfile]) async throws
}
```

Default adapters may include:

- UserDefaults for simple metadata
- SwiftData
- Keychain references
- ephemeral in-memory storage

Tailnet node state belongs in Application Support or an app-group container, never directly in preferences.

State storage should support:

- configurable file protection
- per-profile directories
- deterministic cleanup
- migration hooks
- corruption detection
- export-free secure deletion semantics where practical

## 10. Authentication design

Supported initial modes:

- Interactive login
- Optional auth key injection
- Custom control URL
- Existing state reuse

The package should expose login requirements as state rather than opening URLs automatically.

Applications decide whether to use:

- `openURL`
- `ASWebAuthenticationSession`
- an enterprise enrollment flow
- a copied login URL
- a QR code

## 11. Relay design

The current loopback relay remains the initial compatibility transport.

Requirements:

- Bind only to loopback by default
- Use an ephemeral port
- Support one-shot and reusable relay policies
- Enforce destination immutability
- Propagate EOF and half-close semantics
- Close both sides on cancellation
- Track active connections
- Avoid logging payloads
- Expose bounded diagnostics

## 12. Future native stream bridge

A later high-performance transport may replace local TCP with a direct Swift/Go byte bridge.

Potential architecture:

```text
Swift AsyncSequence or NIO Channel
    <- bounded native buffers ->
Go connection pump
    <->
tsnet net.Conn
```

Goals:

- fewer copies
- fewer system calls
- direct backpressure
- lower latency
- cleaner cancellation
- no local TCP flow-control layer

This is not required before the first public release.

## 13. System Tailscale backend

A lightweight backend should eventually support applications that rely on the installed Tailscale VPN.

Responsibilities:

- normal Apple networking
- reachability diagnostics
- MagicDNS failure hints
- system VPN status heuristics where APIs permit
- deep links to Tailscale
- no Go binary dependency

It should not claim to control Tailscale's VPN lifecycle.

## 14. SwiftUI design

TailnetKitUI should provide small composable views rather than application navigation.

Candidate components:

- `TailnetStatusView`
- `TailnetLoginView`
- `TailnetApprovalView`
- `TailnetPeerPicker`
- `TailnetDiagnosticsView`
- `TailnetProfileForm`
- `TailnetConnectionButton`

The library must allow full custom UI.

## 15. Diagnostics

Diagnostics should include:

- current lifecycle state
- profile identity
- upstream engine version
- bridge protocol version
- control-plane reachability
- assigned addresses
- peer count
- direct versus relayed path information when available
- current DERP region
- relay count
- recent non-sensitive errors
- state-directory health
- network path class
- build metadata

Diagnostics export must redact:

- credentials
- login URLs
- private keys
- sensitive control data
- payload content

## 16. Apple-platform integrations

Core candidates:

- `NWPathMonitor`
- Network.framework for system mode
- Keychain
- Secure Enclave for application-level identity
- LocalAuthentication and Face ID
- SwiftUI observation
- background-aware lifecycle handling
- App Groups where an extension is later added

Optional moonshots:

- tvOS media transport
- AVPlayer-compatible proxy
- custom SwiftNIO channel
- QUIC application gateway protocol
- Handoff between Mac and iPhone
- nearby enrollment bootstrap
- packet-tunnel product in a separate repository or target

## 17. Swift-native reimplementation of only tsnet

A Swift-native reimplementation of the `tsnet` use case is meaningfully smaller than porting all of Tailscale, but it remains a large systems project.

The target would not be a full system VPN client. It would be:

> An application-scoped Swift tailnet node capable of joining a tailnet, discovering peers, establishing direct or DERP-backed paths, and providing outbound TCP or UDP connections.

It would still need substantial functionality:

- control-plane client
- node identity and key lifecycle
- netmap parsing
- endpoint discovery
- STUN
- DERP
- WireGuard data plane
- NAT traversal
- peer path selection
- roaming
- DNS or name-resolution behavior
- outbound userspace networking
- protocol compatibility testing

It could omit, at least initially:

- system-wide VPN routing
- subnet routing
- exit nodes
- full DNS integration
- GUI administration
- all Tailscale client features unrelated to app-scoped dialing

This remains an optional research branch, not a prerequisite for TailnetKit.

Its best justification would be deeper Apple integration, not ordinary performance.

## 18. Non-goals for the first public release

- Native Swift WireGuard implementation
- Native Swift DERP implementation
- Packet tunnel
- watchOS data plane
- UDP
- HTTP/3
- service discovery beyond peer metadata
- app capabilities
- iCloud profile synchronization
- Secure Enclave device enrollment
- binary compatibility across arbitrary Tailscale versions
