// Shared handle layout. orientation.c owns the estimate, live.c owns the sensor thread.
#ifndef WABE_INTERNAL_H
#define WABE_INTERNAL_H

#include "include/wabe.h"
#include "third_party/wabe_vqf.h"

#include <pthread.h>
#include <stdio.h>

/// Measured period of the hinge encoder: it reports 0.01 deg but only refreshes on this grid, so
/// everything that models the lid in time is pinned to it. See NOTES.md for the measurement.
#define WABE_LID_PERIOD 0.1005

/// Reconstructs the lid angle between hinge samples; see lid_filter.c for why it has to.
typedef struct {
    double x, v;      // angle (deg) and rate (deg/s), the tracker's state
    double t;         // time of the last correction
    double y, ty;     // output stage and its clock
    double last_raw;  // last reading accepted, to tell a fresh sample from a repeated poll
    int primed;
} wabe_lid_filter;

void wabe_lid_filter_reset(wabe_lid_filter *f);
void wabe_lid_filter_push(wabe_lid_filter *f, double deg, double now);
double wabe_lid_filter_value(wabe_lid_filter *f, double now);

struct wabe {
    wvqf *vqf;
    double q[4];          // base -> world, w x y z
    double ref[4];        // heading reference (recenter)
    double bias[3];       // rad/s
    int rest;
    double last_accel[3]; // base frame, g (zero-order hold)
    int have_accel;
    wabe_lid_filter lid;
    double last_t;
    int first;
    /// Degrees per count of the hinge encoder; 0 on a machine with none. Zero for replay handles,
    /// which never touch a sensor.
    double lid_resolution;
    /// Set on handles fed from a recording. Everything timed against the clock the samples carry
    /// rather than the wall clock reads this; see wabe_clock() in orientation.c.
    int replay;

    // Live mode only: a thread drains the sensors into the estimate above.
    pthread_mutex_t lock;
    pthread_t thread;
    int tracking;
    FILE *recorder;
};

/// The clock everything internal is timed on: CLOCK_MONOTONIC, the same base ws_sample.t carries.
/// Intervals measured against it — the lid filter's reconstruction, the daemon's publish grid —
/// survive an NTP step, and a recording stamped with it stays alignable against its own samples.
double wabe_now(void);

/// Wall time, for the two places that mean a date rather than an interval: the timestamp the
/// daemon publishes and the start marker in a recording. Never for measuring an elapsed anything.
double wabe_wall_now(void);

#endif
