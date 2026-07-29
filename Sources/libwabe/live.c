// Live tracking: wake the SPU sensors, drain them on a background thread, keep the estimate in
// orientation.c current. This is what makes wabe usable as a service rather than a loop you
// have to write yourself.
#include "internal.h"
#include "wabe_sensor.h"

#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define DRAIN_CAP 2048
#define LID_POLL_EVERY 50  // drain iterations between lid polls (~100 ms at 2 ms/iteration)

double wabe_now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static void widen(const ws_sample *in, wabe_sample *out, size_t n)
{
    for (size_t i = 0; i < n; i++) {
        out[i].t = in[i].t;
        out[i].v[0] = in[i].x;
        out[i].v[1] = in[i].y;
        out[i].v[2] = in[i].z;
    }
}

static void record_samples(FILE *f, char tag, const wabe_sample *s, size_t n)
{
    for (size_t i = 0; i < n; i++)
        fprintf(f, "{\"s\":\"%c\",\"t\":%.6f,\"v\":[%.9g,%.9g,%.9g]}\n",
                tag, s[i].t, s[i].v[0], s[i].v[1], s[i].v[2]);
}

static void *drain_loop(void *arg)
{
    wabe *w = arg;
    static ws_sample accel_raw[DRAIN_CAP], gyro_raw[DRAIN_CAP];
    static wabe_sample accel[DRAIN_CAP], gyro[DRAIN_CAP];
    int since_lid = LID_POLL_EVERY;

    while (w->tracking) {
        const size_t na = ws_read_accel(accel_raw, DRAIN_CAP);
        const size_t ng = ws_read_gyro(gyro_raw, DRAIN_CAP);
        widen(accel_raw, accel, na);
        widen(gyro_raw, gyro, ng);
        wabe_feed(w, accel, na, gyro, ng);

        if (w->recorder) {
            record_samples(w->recorder, 'a', accel, na);
            record_samples(w->recorder, 'g', gyro, ng);
        }

        if (w->handler) {
            const double now = wabe_now();
            if (now - w->handler_last >= w->handler_interval) {
                w->handler_last = now;
                wabe_orientation o;
                wabe_read(w, &o);
                void (*fn)(const wabe_orientation *, void *) = w->handler;
                void *ctx = w->handler_ctx;
                if (w->handler_queue) {
                    // Copy: the handler outlives this iteration's stack.
                    wabe_orientation *copy = malloc(sizeof(o));
                    if (copy) {
                        *copy = o;
                        dispatch_async(w->handler_queue, ^{
                            fn(copy, ctx);
                            free(copy);
                        });
                    }
                } else {
                    fn(&o, ctx);
                }
            }
        }

        if (++since_lid >= LID_POLL_EVERY) {
            since_lid = 0;
            const double d = ws_lid_deg();
            if (d >= 0) {
                wabe_set_lid(w, d);
                if (w->recorder) {
                    fprintf(w->recorder, "{\"s\":\"l\",\"t\":%.6f,\"d\":%.2f}\n", wabe_now(), d);
                    fflush(w->recorder);
                }
            }
        }
        usleep(2000);
    }
    return NULL;
}

wabe *wabe_start(const wabe_options *cfg, int *err)
{
    const int sensor_hz = cfg && cfg->sensor_hz > 0 ? cfg->sensor_hz : 795;
    const char *record_path = cfg ? cfg->record_path : NULL;
    int dummy;
    if (!err)
        err = &dummy;
    *err = WABE_OK;

    int interval = 1000000 / sensor_hz;
    if (interval < 1)
        interval = 1;
    // WABE_NO_WAKE: skip the driver property writes (sensors must already be awake).
    if (!getenv("WABE_NO_WAKE") && ws_wake(interval) <= 0) {
        *err = WABE_ERR_WAKE;
        return NULL;
    }
    if (ws_start() != 0) {
        *err = WABE_ERR_OPEN;
        return NULL;
    }
    // The accelerometer stream is stochastically dead per process instance and nothing
    // in-process revives it (see NOTES.md). Callers re-exec on this error for a fresh roll.
    if (!(ws_opened_mask() & 1)) {
        ws_stop();
        *err = WABE_ERR_ACCEL_DEAD;
        return NULL;
    }

    wabe *w = wabe_replay(sensor_hz);
    if (!w) {
        ws_stop();
        *err = WABE_ERR_OPEN;
        return NULL;
    }

    if (record_path) {
        w->recorder = fopen(record_path, "w");
        if (!w->recorder) {
            wabe_stop(w);
            *err = WABE_ERR_RECORD;
            return NULL;
        }
        setvbuf(w->recorder, NULL, _IOFBF, 1 << 16);
        fprintf(w->recorder, "{\"s\":\"meta\",\"rate\":%d,\"start\":%.6f}\n", sensor_hz, wabe_now());
    }

    w->tracking = 1;
    if (pthread_create(&w->thread, NULL, drain_loop, w) != 0) {
        w->tracking = 0;
        wabe_stop(w);
        *err = WABE_ERR_OPEN;
        return NULL;
    }
    return w;
}

void wabe_on_update(wabe *w, double hz, dispatch_queue_t queue,
                    void (*handler)(const wabe_orientation *o, void *ctx), void *ctx)
{
    pthread_mutex_lock(&w->lock);
    w->handler = handler;
    w->handler_ctx = ctx;
    w->handler_queue = queue;
    w->handler_interval = hz > 0 ? 1.0 / hz : 0;
    w->handler_last = 0;
    pthread_mutex_unlock(&w->lock);
}

void wabe_stop(wabe *w)
{
    if (!w)
        return;
    if (w->tracking) {
        w->tracking = 0;
        pthread_join(w->thread, NULL);
        ws_stop();
    }
    if (w->recorder)
        fclose(w->recorder);
    pthread_mutex_destroy(&w->lock);
    wvqf_destroy(w->vqf);
    free(w);
}
