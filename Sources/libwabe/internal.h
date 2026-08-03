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

/// Anchors kept for the reconstruction. Four is what a centred slope at both ends of the
/// interpolated span needs, and holding more would only be state the output cannot reach.
#define WABE_LID_ANCHORS 4

/// Reconstructs the lid angle between hinge samples; see lid_filter.c for why it has to.
typedef struct {
    double t[WABE_LID_ANCHORS];  // sample times, newest first
    double a[WABE_LID_ANCHORS];  // angles at those times, denoised
    int n;                       // anchors held, saturating at WABE_LID_ANCHORS
    double last_raw;             // last reading accepted, to tell a fresh sample from a repeat
} wabe_lid_filter;

void wabe_lid_filter_reset(wabe_lid_filter *f);
void wabe_lid_filter_push(wabe_lid_filter *f, double deg, double now);

/// Angle at `now`, which the reconstruction reaches one encoder period after the hinge did. Pure:
/// the reading does not depend on how often it is taken.
double wabe_lid_filter_value(const wabe_lid_filter *f, double now);

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
    /// Degrees per count of the hinge encoder; 0 on a machine with none, and on replay handles.
    double lid_resolution;
    /// Set on handles fed from a recording; see wabe_clock() in orientation.c.
    int replay;

    // Live mode only: a thread drains the sensors into the estimate above.
    pthread_mutex_t lock;
    pthread_t thread;
    int tracking;
    FILE *recorder;
};

/// Every interval the library measures is timed on this: CLOCK_MONOTONIC, the base ws_sample.t
/// carries.
double wabe_now(void);

/// Wall time, for the two dates: the timestamp the daemon publishes and a recording's start.
double wabe_wall_now(void);

#endif
