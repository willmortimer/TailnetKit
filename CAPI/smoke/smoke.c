// Standalone C probe for the c-archive boundary. Links libtailnetcore.a directly
// (no SwiftPM, no Swift binding) and drives a Tier-1 login flow against the real
// control plane, exercising: export-symbol resolution, hand-written header / struct
// layout match, the callback function-pointer + ctx round-trip, and string ownership.
//
// Build/run is driven by Scripts/carchive-smoke.sh. Exit 0 if a login URL (or a
// running state) was observed via the callback.

#include <stdio.h>
#include <stdlib.h>

#include "tailnetcore.h"

struct probe {
    int events;
    int saw_login;
    int saw_running;
};

static void on_event(void *ctx, const tnk_event *event) {
    struct probe *p = (struct probe *)ctx;
    p->events++;
    switch (event->kind) {
    case TNK_EVENT_LOGIN_URL:
        printf("[event] login_url: %s\n", event->url ? event->url : "(null)");
        p->saw_login = 1;
        break;
    case TNK_EVENT_ERROR:
        printf("[event] error: %s\n", event->msg ? event->msg : "(null)");
        break;
    case TNK_EVENT_STATE:
        printf("[event] state: phase=%d url=%s\n", event->state.phase,
               event->state.url ? event->state.url : "");
        if (event->state.phase == TNK_PHASE_NEEDS_LOGIN) p->saw_login = 1;
        if (event->state.phase == TNK_PHASE_RUNNING) p->saw_running = 1;
        break;
    }
}

int main(int argc, char **argv) {
    const char *dir = (argc > 1) ? argv[1] : "/tmp/tnk-carchive-smoke";

    printf("[probe] protocol version: %d\n", tnk_protocol_version());

    tnk_bridge h = tnk_new_bridge();
    if (h == 0) {
        fprintf(stderr, "[probe] tnk_new_bridge failed\n");
        return 1;
    }

    struct probe p = {0, 0, 0};
    tnk_set_listener(h, on_event, &p);

    tnk_profile profile = {
        .id = "main",
        .display_name = "probe",
        .hostname = "tnk-carchive-smoke",
        .control_url = NULL,
        .state_dir = dir,
    };

    char *err = tnk_start(h, &profile);
    if (err != NULL) {
        fprintf(stderr, "[probe] tnk_start error: %s\n", err);
        tnk_free(err);
        tnk_free_bridge(h);
        return 1;
    }

    tnk_state state = {0};
    char *serr = tnk_get_state(h, "main", &state);
    if (serr != NULL) {
        fprintf(stderr, "[probe] tnk_get_state error: %s\n", serr);
        tnk_free(serr);
    } else {
        printf("[state] phase=%d url=%s\n", state.phase, state.url ? state.url : "");
        tnk_free_state(&state);
    }

    char *stop_err = tnk_stop(h, "main");
    if (stop_err != NULL) tnk_free(stop_err);
    tnk_free_bridge(h);

    printf("[probe] events=%d saw_login=%d saw_running=%d\n", p.events, p.saw_login, p.saw_running);
    return (p.saw_login || p.saw_running) ? 0 : 2;
}
