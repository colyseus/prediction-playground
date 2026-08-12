/*
 * Latency injector for the native SDK (APPS_PLAN §3).
 *
 * The web playground gets delay/jitter from the JS SDK's debug panel; on
 * localhost every other SDK needs its own injector or labs 00/01/03 demonstrate
 * nothing. This one decorates the transport: `nd_transport_create` is handed to
 * `colyseus_client_create_with_transport`, so the room builds (and, on
 * reconnect, REBUILDS) a wrapper that owns a real websocket transport and
 * queues both directions.
 *
 * Three properties are load-bearing:
 *
 *   - No reordering. Each packet's deliver-at is clamped to >= the previous
 *     one's; the wire is a stream and TCP never reorders. (Same rule the JS
 *     debug panel follows.)
 *   - Inbound frames are drained from `nd_pump()` on the MAIN thread. The SDK
 *     decodes inside on_message, so this moves every decode off the transport
 *     thread — the app reads schema state without a mutex, and a `delay 0`
 *     injector is still worth keeping installed.
 *   - Wrappers are only ever destroyed BY the pump. The SDK's reconnection
 *     worker calls destroy() from its own thread; doing the teardown there
 *     would race the pump on the inner transport, and taking the registry lock
 *     across an SDK call would invert lock order against the worker's mutex.
 *     destroy() therefore just marks, and the main thread reaps.
 *
 * `nd_drop()` closes the socket uncleanly (4010, MAY_TRY_RECONNECT) so the
 * SDK's auto-reconnect kicks in — the `K` key in the app. 4010 rather than
 * 1006: browsers forbid script-initiated close(1006), and the web build
 * issues the close through the page's WebSocket.
 */
#ifndef PLAYGROUND_NET_DELAY_H
#define PLAYGROUND_NET_DELAY_H

#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "colyseus/transport.h"
#include "colyseus/protocol.h"
#include "colyseus/websocket_transport.h"

#define ND_MAX_TRANSPORTS 16

typedef enum { ND_OPEN, ND_MESSAGE, ND_CLOSE, ND_ERROR } nd_kind_t;

typedef struct nd_packet {
    struct nd_packet* next;
    double deliver_at;
    nd_kind_t kind;
    uint8_t* data;      /* ND_MESSAGE */
    size_t len;
    int code;           /* ND_CLOSE */
    char* text;         /* ND_CLOSE reason / ND_ERROR message */
} nd_packet_t;

typedef struct {
    nd_packet_t* head;
    nd_packet_t* tail;
    double last_deliver;   /* monotonic clamp — packets never reorder */
} nd_queue_t;

typedef struct {
    /* MUST be first: the SDK hands us back a colyseus_transport_t*. */
    colyseus_transport_t base;
    colyseus_transport_t* inner;
    colyseus_transport_events_t app;   /* the room's handlers */
    pthread_mutex_t lock;              /* guards the two queues only */
    nd_queue_t inbound;                /* server -> app  (drained on main) */
    nd_queue_t outbound;               /* app -> server */
    bool closed;                       /* a close has been delivered upward */
    bool discarded;                    /* destroy() called; awaiting the reaper */
} nd_transport_t;

/* ------------------------------------------------------------ globals */

/* Guards the two arrays below and nothing else — never held across an SDK call. */
static pthread_mutex_t nd_registry_lock = PTHREAD_MUTEX_INITIALIZER;
static nd_transport_t* nd_live[ND_MAX_TRANSPORTS];
static int nd_live_count = 0;
static nd_transport_t* nd_discarded[ND_MAX_TRANSPORTS];
static int nd_discarded_count = 0;

static double nd_delay_ms = 0;
static double nd_jitter_ms = 0;
static uint32_t nd_rand_state = 0x9E3779B9u;

/** Monotonic milliseconds — the injector's own clock (no room needed). */
static double nd_now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1e6;
}

static double nd_rand01(void) {
    nd_rand_state = nd_rand_state * 1664525u + 1013904223u;
    return (double)(nd_rand_state >> 8) / 16777216.0;
}

/** One-way delay for the next packet. Round-trip ends up ~2x this. */
static double nd_one_way(void) {
    /* Half the round trip, plus symmetric jitter — the split the JS SDK's
     * __net() uses, so a preset means the same RTT on every client. */
    return (nd_delay_ms + (nd_rand01() * 2.0 - 1.0) * nd_jitter_ms) / 2.0;
}

static void nd_set_latency(double delay_ms, double jitter_ms) {
    nd_delay_ms = delay_ms < 0 ? 0 : delay_ms;
    nd_jitter_ms = jitter_ms < 0 ? 0 : jitter_ms;
}

static double nd_get_delay(void) { return nd_delay_ms; }
static double nd_get_jitter(void) { return nd_jitter_ms; }

/* ------------------------------------------------------------- queues */

/* Caller holds t->lock. */
static void nd_enqueue(nd_queue_t* q, nd_packet_t* p) {
    double at = nd_now() + nd_one_way();
    if (at < q->last_deliver) { at = q->last_deliver; }
    q->last_deliver = at;
    p->deliver_at = at;
    p->next = NULL;
    if (q->tail) { q->tail->next = p; } else { q->head = p; }
    q->tail = p;
}

/* Caller holds t->lock. Returns the due packet (ownership transfers) or NULL. */
static nd_packet_t* nd_dequeue_due(nd_queue_t* q, double now) {
    if (!q->head || q->head->deliver_at > now) { return NULL; }
    nd_packet_t* p = q->head;
    q->head = p->next;
    if (!q->head) { q->tail = NULL; }
    p->next = NULL;
    return p;
}

static void nd_packet_free(nd_packet_t* p) {
    free(p->data);
    free(p->text);
    free(p);
}

static void nd_queue_clear(nd_queue_t* q) {
    nd_packet_t* p = q->head;
    while (p) { nd_packet_t* n = p->next; nd_packet_free(p); p = n; }
    q->head = q->tail = NULL;
}

static nd_packet_t* nd_packet_new(nd_kind_t kind) {
    nd_packet_t* p = (nd_packet_t*)calloc(1, sizeof(nd_packet_t));
    p->kind = kind;
    return p;
}

static void nd_push(nd_transport_t* t, nd_queue_t* q, nd_packet_t* p) {
    pthread_mutex_lock(&t->lock);
    nd_enqueue(q, p);
    pthread_mutex_unlock(&t->lock);
}

/* ------------------------------------------- inner transport handlers */
/* These run on the websocket tick thread. Enqueue only — never decode here. */

static void nd_inner_on_open(void* userdata) {
    nd_transport_t* t = (nd_transport_t*)userdata;
    nd_push(t, &t->inbound, nd_packet_new(ND_OPEN));
}

static void nd_inner_on_message(const uint8_t* data, size_t length, void* userdata) {
    nd_transport_t* t = (nd_transport_t*)userdata;
    nd_packet_t* p = nd_packet_new(ND_MESSAGE);
    p->data = (uint8_t*)malloc(length ? length : 1);
    memcpy(p->data, data, length);
    p->len = length;
    nd_push(t, &t->inbound, p);
}

static void nd_inner_on_close(int code, const char* reason, void* userdata) {
    nd_transport_t* t = (nd_transport_t*)userdata;
    nd_packet_t* p = nd_packet_new(ND_CLOSE);
    p->code = code;
    p->text = reason ? strdup(reason) : NULL;
    nd_push(t, &t->inbound, p);
}

static void nd_inner_on_error(const char* error, void* userdata) {
    nd_transport_t* t = (nd_transport_t*)userdata;
    nd_packet_t* p = nd_packet_new(ND_ERROR);
    p->text = error ? strdup(error) : NULL;
    nd_push(t, &t->inbound, p);
}

/* -------------------------------------------------- wrapper vtable */

static void nd_connect(colyseus_transport_t* transport, const char* url) {
    colyseus_transport_connect(((nd_transport_t*)transport)->inner, url);
}

static void nd_send(colyseus_transport_t* transport, const uint8_t* data, size_t length) {
    nd_transport_t* t = (nd_transport_t*)transport;
    nd_packet_t* p = nd_packet_new(ND_MESSAGE);
    p->data = (uint8_t*)malloc(length ? length : 1);
    memcpy(p->data, data, length);
    p->len = length;
    nd_push(t, &t->outbound, p);
}

static void nd_send_unreliable(colyseus_transport_t* transport, const uint8_t* data, size_t length) {
    nd_send(transport, data, length);
}

static void nd_close(colyseus_transport_t* transport, int code, const char* reason) {
    colyseus_transport_close(((nd_transport_t*)transport)->inner, code, reason);
}

static bool nd_is_open(const colyseus_transport_t* transport) {
    return colyseus_transport_is_open(((const nd_transport_t*)transport)->inner);
}

/* Called by the SDK, possibly from the reconnection worker: mark only. */
static void nd_destroy(colyseus_transport_t* transport) {
    nd_transport_t* t = (nd_transport_t*)transport;
    pthread_mutex_lock(&nd_registry_lock);
    for (int i = 0; i < nd_live_count; i++) {
        if (nd_live[i] == t) { nd_live[i] = nd_live[--nd_live_count]; break; }
    }
    t->discarded = true;
    if (nd_discarded_count < ND_MAX_TRANSPORTS) { nd_discarded[nd_discarded_count++] = t; }
    pthread_mutex_unlock(&nd_registry_lock);
}

/**
 * Transport factory — pass to colyseus_client_create_with_transport().
 * The room calls this again on every reconnect attempt, so the injector
 * survives drops for free.
 */
static colyseus_transport_t* nd_transport_create(const colyseus_transport_events_t* events) {
    nd_transport_t* t = (nd_transport_t*)calloc(1, sizeof(nd_transport_t));
    pthread_mutex_init(&t->lock, NULL);
    if (events) { t->app = *events; }

    colyseus_transport_events_t inner_events = {
        .on_open = nd_inner_on_open,
        .on_message = nd_inner_on_message,
        .on_close = nd_inner_on_close,
        .on_error = nd_inner_on_error,
        .userdata = t,
    };
    t->inner = colyseus_websocket_transport_create(&inner_events);
    if (!t->inner) { pthread_mutex_destroy(&t->lock); free(t); return NULL; }

    t->base.connect = nd_connect;
    t->base.send = nd_send;
    t->base.send_unreliable = nd_send_unreliable;
    t->base.close = nd_close;
    t->base.is_open = nd_is_open;
    t->base.destroy = nd_destroy;
    t->base.events = t->app;
    /*
     * colyseus_websocket_connect_with_settings() writes TLS config straight
     * through transport->impl_data before calling connect — aliasing the inner
     * websocket's impl_data makes that land on the real socket instead of
     * corrupting our struct.
     */
    t->base.impl_data = t->inner->impl_data;

    pthread_mutex_lock(&nd_registry_lock);
    if (nd_live_count < ND_MAX_TRANSPORTS) { nd_live[nd_live_count++] = t; }
    pthread_mutex_unlock(&nd_registry_lock);
    return &t->base;
}

/* ------------------------------------------------------------- pump */

static void nd_pump_one(nd_transport_t* t, double now) {
    nd_packet_t* p;

    /* Outbound: hand due frames to the real socket. */
    for (;;) {
        pthread_mutex_lock(&t->lock);
        p = nd_dequeue_due(&t->outbound, now);
        pthread_mutex_unlock(&t->lock);
        if (!p) { break; }
        if (!t->discarded) { colyseus_transport_send(t->inner, p->data, p->len); }
        nd_packet_free(p);
    }

    /* Inbound: deliver on THIS thread — the SDK decodes inside on_message. */
    for (;;) {
        pthread_mutex_lock(&t->lock);
        p = nd_dequeue_due(&t->inbound, now);
        pthread_mutex_unlock(&t->lock);
        if (!p) { break; }
        if (!t->discarded) {
            switch (p->kind) {
                case ND_OPEN:
                    if (t->app.on_open) { t->app.on_open(t->app.userdata); }
                    break;
                case ND_MESSAGE:
                    if (t->app.on_message) { t->app.on_message(p->data, p->len, t->app.userdata); }
                    break;
                case ND_CLOSE:
                    t->closed = true;
                    if (t->app.on_close) { t->app.on_close(p->code, p->text, t->app.userdata); }
                    break;
                case ND_ERROR:
                    if (t->app.on_error) { t->app.on_error(p->text, t->app.userdata); }
                    break;
            }
        }
        nd_packet_free(p);
        /* on_close may have spawned a reconnect that discarded us mid-drain. */
        if (t->discarded || t->closed) { break; }
    }
}

/** Free wrappers the SDK let go of. Main thread only (see the header note). */
static void nd_reap(void) {
    for (;;) {
        nd_transport_t* t = NULL;
        pthread_mutex_lock(&nd_registry_lock);
        if (nd_discarded_count > 0) { t = nd_discarded[--nd_discarded_count]; }
        pthread_mutex_unlock(&nd_registry_lock);
        if (!t) { break; }
        colyseus_transport_destroy(t->inner);   /* joins the tick thread */
        nd_queue_clear(&t->inbound);
        nd_queue_clear(&t->outbound);
        pthread_mutex_destroy(&t->lock);
        free(t);
    }
}

/** Drain every due packet. Call once per frame from the render loop. */
static void nd_pump(void) {
    nd_transport_t* snapshot[ND_MAX_TRANSPORTS];
    int n;
    pthread_mutex_lock(&nd_registry_lock);
    n = nd_live_count;
    memcpy(snapshot, nd_live, sizeof(nd_transport_t*) * (size_t)n);
    pthread_mutex_unlock(&nd_registry_lock);

    double now = nd_now();
    for (int i = 0; i < n; i++) { nd_pump_one(snapshot[i], now); }
    nd_reap();
}

/**
 * Kill every live socket uncleanly (close code 4010) — the SDK sees a drop,
 * not a leave, and its reconnection worker takes over.
 */
static void nd_drop(void) {
    colyseus_transport_t* inners[ND_MAX_TRANSPORTS];
    int n = 0;
    pthread_mutex_lock(&nd_registry_lock);
    for (int i = 0; i < nd_live_count; i++) {
        if (!nd_live[i]->closed) { inners[n++] = nd_live[i]->inner; }
    }
    pthread_mutex_unlock(&nd_registry_lock);
    for (int i = 0; i < n; i++) {
        colyseus_transport_close(inners[i], COLYSEUS_CLOSE_MAY_TRY_RECONNECT, "simulated drop");
    }
}

/** Queued packets in both directions, for the HUD. */
static int nd_inflight(void) {
    int n = 0;
    pthread_mutex_lock(&nd_registry_lock);
    for (int i = 0; i < nd_live_count; i++) {
        nd_transport_t* t = nd_live[i];
        pthread_mutex_lock(&t->lock);
        for (nd_packet_t* p = t->inbound.head; p; p = p->next) { n++; }
        for (nd_packet_t* p = t->outbound.head; p; p = p->next) { n++; }
        pthread_mutex_unlock(&t->lock);
    }
    pthread_mutex_unlock(&nd_registry_lock);
    return n;
}

#endif /* PLAYGROUND_NET_DELAY_H */
