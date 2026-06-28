// TailnetCore — flat C ABI over an embedded tsnet node.
//
// Built from Go/capi via `go build -buildmode=c-archive` and packaged into
// TailnetCore.xcframework. The Swift layer in TailnetKitEmbedded is the only
// intended caller. This is the hand-written counterpart to cgo's generated header;
// the symbols must stay in sync with the //export directives in tailnetcore.go.
//
// Memory & threading:
//   - Functions returning `char *` return NULL on success or a malloc'd, caller-owned
//     message on failure. Release every non-NULL `char *` (errors and out-strings)
//     with tnk_free.
//   - The `json` passed to the event callback is owned by the library and valid only
//     for the duration of the call. Copy it before returning.
//   - The callback fires on an internal Go thread. Callers must not assume a queue.

#ifndef TAILNETCORE_H
#define TAILNETCORE_H

#include <stdlib.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque bridge handle (> 0 when valid).
typedef long long tnk_bridge;

// Event callback. `ctx` is the pointer passed to tnk_set_listener; `json` is a
// transient, library-owned UTF-8 string.
typedef void (*tnk_event_cb)(void *ctx, const char *json);

// ABI version of this surface. A mismatch with the Swift layer is rejected.
int tnk_protocol_version(void);

// Create a bridge. Returns a handle (> 0) or 0 on failure.
tnk_bridge tnk_new_bridge(void);

// Release a bridge handle. Stop the node first; this does not shut tsnet down.
void tnk_free_bridge(tnk_bridge h);

// Register (or clear, with cb == NULL) the event callback. `ctx` is passed back on
// every invocation.
void tnk_set_listener(tnk_bridge h, tnk_event_cb cb, void *ctx);

// Boot tsnet for the profile JSON (TailnetProfile fields plus a stateDir path).
// Blocks until login is required, the node is running, or device approval is needed.
char *tnk_start(tnk_bridge h, const char *profile_json);

// Shut the profile's tsnet server down.
char *tnk_stop(tnk_bridge h, const char *profile_id);

// Write JSON-encoded lifecycle state for the profile to *out_json (caller frees).
char *tnk_state_json(tnk_bridge h, const char *profile_id, char **out_json);

// Write a JSON-encoded peer array for the profile to *out_json (caller frees).
char *tnk_peers_json(tnk_bridge h, const char *profile_id, char **out_json);

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
