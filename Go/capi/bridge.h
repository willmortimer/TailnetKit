#ifndef TAILNETKIT_BRIDGE_H
#define TAILNETKIT_BRIDGE_H

#include <stdlib.h>

// Event callback invoked from Go on tailnet lifecycle changes. `json` is owned by
// Go and only valid for the duration of the call — copy it before returning.
typedef void (*tnk_event_cb)(void *ctx, const char *json);

// Trampoline so Go can call a C function pointer (cgo cannot call one directly).
// static inline keeps it out of the export translation unit's symbol table, which
// the //export restriction requires (the preamble must not define external symbols).
static inline void tnk_invoke_event_cb(tnk_event_cb cb, void *ctx, const char *json) {
    cb(ctx, json);
}

#endif /* TAILNETKIT_BRIDGE_H */
