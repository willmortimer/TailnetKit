// TailnetCore — flat, typed C ABI over an embedded tsnet node.
//
// Built from Go/capi via `go build -buildmode=c-archive` and packaged into
// TailnetCore.xcframework. The Swift layer in TailnetKitEmbedded is the only
// intended caller. This is the hand-written counterpart to cgo's generated header;
// the symbols and struct layouts must stay in sync with Go/capi (tailnetcore.go +
// bridge.h). A struct-layout mismatch corrupts memory — keep field order identical.
//
// Memory & threading:
//   - Functions returning `char *` return NULL on success or a malloc'd, caller-owned
//     message on failure. Release it with tnk_free.
//   - tnk_get_state fills caller-owned storage with library-owned strings; release
//     them with tnk_free_state. tnk_get_peers allocates an array; release it with
//     tnk_free_peers.
//   - The tnk_event passed to the callback is library-owned and valid only for the
//     duration of the call. Copy what you need before returning.
//   - The callback fires on an internal Go thread. Callers must not assume a queue.

#ifndef TAILNETCORE_H
#define TAILNETCORE_H

#include <stdlib.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque bridge handle (> 0 when valid).
typedef long long tnk_bridge;

// Lifecycle phase. Mirrors the engine's state machine.
typedef enum {
    TNK_PHASE_STOPPED = 0,
    TNK_PHASE_STARTING = 1,
    TNK_PHASE_NEEDS_LOGIN = 2,
    TNK_PHASE_NEEDS_DEVICE_APPROVAL = 3,
    TNK_PHASE_RUNNING = 4,
    TNK_PHASE_FAILED = 5
} tnk_phase;

// Node configuration passed to tnk_start. All strings are caller-owned.
typedef struct {
    const char *id;
    const char *display_name;
    const char *hostname;
    const char *control_url; // nullable
    const char *state_dir;
} tnk_profile;

// Lifecycle state. String fields are nullable and library-owned (free with
// tnk_free_state). url is set for NEEDS_LOGIN; ipv4/ipv6/dns_name/host_name for
// RUNNING; msg for FAILED.
typedef struct {
    tnk_phase phase;
    char *ipv4;
    char *ipv6;
    char *dns_name;
    char *host_name;
    char *url;
    char *msg;
} tnk_state;

// One tailnet peer. Strings are library-owned (freed by tnk_free_peers).
typedef struct {
    char *id;
    char *dns_name;
    char *host_name;
    char *tailscale_ip;
    char *os;
    int online;
    int ssh_enabled;
} tnk_peer;

typedef enum {
    TNK_EVENT_STATE = 0,
    TNK_EVENT_LOGIN_URL = 1,
    TNK_EVENT_ERROR = 2
} tnk_event_kind;

// A lifecycle event. The active member depends on `kind`.
typedef struct {
    tnk_event_kind kind;
    tnk_state state; // valid when kind == TNK_EVENT_STATE
    char *url;       // valid when kind == TNK_EVENT_LOGIN_URL
    char *msg;       // valid when kind == TNK_EVENT_ERROR
} tnk_event;

// Event callback. `ctx` is the pointer passed to tnk_set_listener; `event` is a
// transient, library-owned value.
typedef void (*tnk_event_cb)(void *ctx, const tnk_event *event);

// ABI version of this surface. A mismatch with the Swift layer is rejected.
int tnk_protocol_version(void);

// Create a bridge. Returns a handle (> 0) or 0 on failure.
tnk_bridge tnk_new_bridge(void);

// Release a bridge handle. Stop the node first; this does not shut tsnet down.
void tnk_free_bridge(tnk_bridge h);

// Register (or clear, with cb == NULL) the event callback.
void tnk_set_listener(tnk_bridge h, tnk_event_cb cb, void *ctx);

// Boot tsnet for the profile. Blocks until login is required, the node is running,
// or device approval is needed.
char *tnk_start(tnk_bridge h, const tnk_profile *profile);

// Shut the profile's tsnet server down.
char *tnk_stop(tnk_bridge h, const char *profile_id);

// Fill *out with the profile's lifecycle state. Release with tnk_free_state.
char *tnk_get_state(tnk_bridge h, const char *profile_id, tnk_state *out);

// Release the library-owned strings inside a state struct.
void tnk_free_state(tnk_state *s);

// Allocate and fill an array of the profile's peers; write the count to *out_count.
// Release with tnk_free_peers.
char *tnk_get_peers(tnk_bridge h, const char *profile_id, tnk_peer **out_peers, int *out_count);

// Release a peer array returned by tnk_get_peers.
void tnk_free_peers(tnk_peer *peers, int count);

// Dial host:port over the tailnet; write an opaque connection id to *out_conn.
char *tnk_dial_tcp(tnk_bridge h, const char *profile_id, const char *host, int port, long long *out_conn);

// Read up to `max` bytes from a connection into `buf`; write the count to *out_n.
// A non-NULL return (e.g. "EOF") signals the connection is finished.
char *tnk_conn_read(tnk_bridge h, long long conn_id, void *buf, int max, int *out_n);

// Write `length` bytes from `data` to a connection.
char *tnk_conn_write(tnk_bridge h, long long conn_id, const void *data, int length);

// Close a dialed connection.
char *tnk_conn_close(tnk_bridge h, long long conn_id);

// Bind 127.0.0.1:0 and proxy one inbound connection to host:port over the tailnet.
// Write the chosen loopback port to *out_port.
char *tnk_open_loopback_relay(tnk_bridge h, const char *profile_id, const char *host, int port, int *out_port);

// Check an SSH host-key fingerprint against the peer's advertised keys. Returns 1 on
// match, 0 otherwise (including any error).
int tnk_verify_ssh_host_key(tnk_bridge h, const char *profile_id, const char *hostname, int port, const char *fingerprint);

// Release a string returned by this library.
void tnk_free(char *p);

#ifdef __cplusplus
}
#endif

#endif /* TAILNETCORE_H */
