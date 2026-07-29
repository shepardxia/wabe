// Shared handle layout. orientation.c owns the estimate, live.c owns the sensor thread.
#ifndef WABE_INTERNAL_H
#define WABE_INTERNAL_H

#include "include/wabe.h"
#include "vendor/wabe_vqf.h"

#include <pthread.h>
#include <stdio.h>

struct wabe {
    wvqf *vqf;
    double q[4];          // base -> world, w x y z
    double ref[4];        // heading reference (recenter)
    double bias[3];       // rad/s
    int rest;
    double last_accel[3]; // base frame, g (zero-order hold)
    int have_accel;
    double lid_deg;
    double last_t;
    int first;

    // Live mode only: a thread drains the sensors into the estimate above.
    pthread_mutex_t lock;
    pthread_t thread;
    int tracking;
    FILE *recorder;

    // Push delivery (wabe_on_update).
    void (*handler)(const wabe_orientation *, void *);
    void *handler_ctx;
    dispatch_queue_t handler_queue;
    double handler_interval;
    double handler_last;
};

double wabe_now(void);

#endif
