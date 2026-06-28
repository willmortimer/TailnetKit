#ifndef TAILNETKIT_BRIDGE_H
#define TAILNETKIT_BRIDGE_H

#include <stdlib.h>

// Type definitions for the C ABI. These must stay identical to the public
// CAPI/include/tailnetcore.h (the smoke probe and Swift link against that copy;
// the archive is built against this one). See tailnetcore.h for ownership docs.

typedef enum {
    TNK_PHASE_STOPPED = 0,
    TNK_PHASE_STARTING = 1,
    TNK_PHASE_NEEDS_LOGIN = 2,
    TNK_PHASE_NEEDS_DEVICE_APPROVAL = 3,
    TNK_PHASE_RUNNING = 4,
    TNK_PHASE_FAILED = 5
} tnk_phase;

typedef struct {
    const char *id;
    const char *display_name;
    const char *hostname;
    const char *control_url; // nullable
    const char *state_dir;
} tnk_profile;

typedef struct {
    tnk_phase phase;
    char *ipv4;      // all nullable, library-owned; free with tnk_free_state
    char *ipv6;
    char *dns_name;
    char *host_name;
    char *url;
    char *msg;
} tnk_state;

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

typedef struct {
    tnk_event_kind kind;
    tnk_state state; // valid when kind == TNK_EVENT_STATE
    char *url;       // valid when kind == TNK_EVENT_LOGIN_URL
    char *msg;       // valid when kind == TNK_EVENT_ERROR
} tnk_event;

// Event callback. `event` is owned by the library and valid only during the call.
typedef void (*tnk_event_cb)(void *ctx, const tnk_event *event);

// Trampoline so Go can call a C function pointer (cgo cannot call one directly).
// static inline keeps it out of the export translation unit, which the //export
// restriction requires (the preamble must not define external symbols).
static inline void tnk_invoke_event_cb(tnk_event_cb cb, void *ctx, const tnk_event *event) {
    cb(ctx, event);
}

#endif /* TAILNETKIT_BRIDGE_H */
