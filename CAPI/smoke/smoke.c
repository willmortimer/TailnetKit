// Standalone C probe for the c-archive boundary. Links libtailnetcore.a directly
// (no SwiftPM, no Swift binding) and drives a Tier-1 login flow against the real
// control plane, exercising: export-symbol resolution, hand-written header match,
// the callback function-pointer + ctx round-trip, and string ownership.
//
// Build/run is driven by Scripts/carchive-smoke.sh. Exit 0 if a login URL (or a
// running state) was observed via the callback.

#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include "tailnetcore.h"

struct probe {
    int events;
    int saw_login;
    int saw_running;
};

static void on_event(void *ctx, const char *json) {
    struct probe *p = (struct probe *)ctx;
    p->events++;
    printf("[event] %s\n", json);
    if (strstr(json, "login") != NULL) p->saw_login = 1;
    if (strstr(json, "running") != NULL) p->saw_running = 1;
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

    char profile[2048];
    snprintf(profile, sizeof(profile),
        "{\"id\":\"main\",\"displayName\":\"probe\",\"hostname\":\"tnk-carchive-smoke\",\"stateDir\":\"%s\"}",
        dir);

    char *err = tnk_start(h, profile);
    if (err != NULL) {
        fprintf(stderr, "[probe] tnk_start error: %s\n", err);
        tnk_free(err);
        tnk_free_bridge(h);
        return 1;
    }

    char *state_json = NULL;
    char *serr = tnk_state_json(h, "main", &state_json);
    if (serr != NULL) {
        fprintf(stderr, "[probe] tnk_state_json error: %s\n", serr);
        tnk_free(serr);
    } else {
        printf("[state] %s\n", state_json ? state_json : "(null)");
        tnk_free(state_json);
    }

    char *stop_err = tnk_stop(h, "main");
    if (stop_err != NULL) tnk_free(stop_err);
    tnk_free_bridge(h);

    printf("[probe] events=%d saw_login=%d saw_running=%d\n", p.events, p.saw_login, p.saw_running);
    return (p.saw_login || p.saw_running) ? 0 : 2;
}
