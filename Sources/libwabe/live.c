// Live tracking: wake the SPU sensors, drain them on a background thread, keep the estimate in
// orientation.c current. This is what makes wabe usable as a service rather than a loop you
// have to write yourself.
#include "internal.h"
#include "wabe_sensor.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define DRAIN_CAP 2048
// Drain iterations between lid polls, at ~2 ms an iteration. One IOHIDDeviceGetReport on the
// hinge measures 0.67 ms mean, 1.48 ms worst on Mac16,6, so polling every 2nd iteration samples
// the lid at ~190 Hz for about 12% of this thread — and 100 Hz is what anything tracking the
// screen plane needs. The old value of 50 left the published lid angle up to 100 ms stale, which
// is not subtle: it reads as lag on any pivot fast enough to be worth watching.
#define LID_POLL_EVERY 2

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
    const int sensor_hz = cfg && cfg->sensor_hz > 0 ? cfg->sensor_hz : WABE_DEFAULT_SENSOR_HZ;
    const char *record_path = cfg ? cfg->record_path : NULL;
    const int skip_wake = cfg ? cfg->skip_wake : 0;
    int dummy;
    if (!err)
        err = &dummy;
    *err = WABE_OK;

    int interval = 1000000 / sensor_hz;
    if (interval < 1)
        interval = 1;
    if (!skip_wake && ws_wake(interval) <= 0) {
        *err = WABE_ERR_WAKE;
        return NULL;
    }
    if (ws_start() != 0) {
        *err = WABE_ERR_OPEN;
        return NULL;
    }
    // The IMU streams are stochastically dead per process instance and nothing in-process
    // revives them (see NOTES.md). Callers re-exec on these for a fresh roll.
    //
    // Both matter, and the gyro matters more than it looks: the estimate only advances on gyro
    // samples, so a live accelerometer with a dead gyro yields a frozen attitude while lid and
    // timestamps keep moving. That reads as a working stream and is not one, so refuse it.
    if (!(ws_opened_mask() & 1)) {
        ws_stop();
        *err = WABE_ERR_ACCEL_DEAD;
        return NULL;
    }
    if (!(ws_opened_mask() & 2)) {
        ws_stop();
        *err = WABE_ERR_GYRO_DEAD;
        return NULL;
    }
    // Reports arrive but no candidate offset produced gravity: the layout is unknown on this
    // machine and parsing it anyway would publish confident nonsense.
    if (!ws_layout_known()) {
        ws_stop();
        *err = WABE_ERR_LAYOUT;
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
            fprintf(stderr, "wabe: cannot write capture to %s: %s\n", record_path, strerror(errno));
            wabe_stop(w);
            *err = WABE_ERR_RECORD;
            return NULL;
        }
        setvbuf(w->recorder, NULL, _IOFBF, 1 << 16);
        fprintf(w->recorder, "{\"s\":\"meta\",\"rate\":%d,\"start\":%.6f}\n", sensor_hz, wabe_now());
    }

    w->lid_resolution = ws_lid_resolution();
    if (w->lid_resolution == 0)
        fprintf(stderr, "wabe: no hinge encoder on this machine; orientation works, "
                        "screen normal does not\n");

    w->tracking = 1;
    if (pthread_create(&w->thread, NULL, drain_loop, w) != 0) {
        w->tracking = 0;
        wabe_stop(w);
        *err = WABE_ERR_OPEN;
        return NULL;
    }

    // Settle the lid before returning, so a negative lid angle means "this machine has no hinge
    // encoder" rather than "the first poll has not landed yet". Consumers read that distinction
    // off the published angle, and it is worth 100 ms at startup to make it honest.
    if (w->lid_resolution > 0) {
        for (int i = 0; i < 30; i++) {
            wabe_orientation o;
            wabe_read(w, &o);
            if (o.lid_deg >= 0)
                break;
            usleep(10000);
        }
    }
    return w;
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
