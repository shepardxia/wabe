// libwabe — pose service core for Apple Silicon MacBooks.
//
// Everything computational lives behind this C API: SPU sensor I/O, sample merging, the
// VQF orientation filter (vendored C++, invisible to consumers), pose extraction, and the
// unix-socket daemon service. Consumers (Swift demo/CLI, any FFI) stay thin.
#ifndef WABE_H
#define WABE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// One chip-frame IMU sample: g for accel, deg/s for gyro, CLOCK_MONOTONIC seconds.
typedef struct {
    double t;
    double v[3];
} wabe_sample;

typedef struct {
    double t;
    double q[4];    // base -> world quaternion (w, x, y, z); base: X right, Y hinge, Z up
    double rpy[3];  // degrees; roll/pitch absolute (gravity), yaw relative to last recenter
    double bias[3]; // gyro bias estimate, deg/s
    double n[3];    // screen-plane normal, world frame (base attitude ⊕ lid angle)
    double lid_deg; // last lid angle fed via wabe_filter_set_lid (-1 if never)
    int stationary; // VQF rest detection
} wabe_pose;

// --- filter (usable offline: feed recorded samples, read poses) ---

typedef struct wabe_filter wabe_filter;

wabe_filter *wabe_filter_new(double sample_hz);
void wabe_filter_free(wabe_filter *f);

// Timestamp-merge chip-frame batches: gyro samples drive filter updates, accel samples
// refresh a zero-order hold used for the gravity correction. Arrays must be time-ascending.
// Chip->base axis maps (measured, see NOTES.md) are applied here.
void wabe_filter_feed(wabe_filter *f, const wabe_sample *accel, size_t na,
                      const wabe_sample *gyro, size_t ng);

void wabe_filter_set_lid(wabe_filter *f, double deg);
void wabe_filter_recenter(wabe_filter *f);
void wabe_filter_pose(const wabe_filter *f, double t, wabe_pose *out);

// --- daemon service ---

typedef struct {
    int sensor_hz;           // 0 -> 795
    double publish_hz;       // 0 -> 30
    const char *socket_path; // NULL -> /tmp/wabe.sock
    const char *record_path; // NULL -> no raw capture; else chip-frame JSONL is appended
} wabe_config;

enum {
    WABE_OK = 0,
    WABE_ERR_WAKE = 1,       // no AppleSPUHIDDriver service accepted the wake properties
    WABE_ERR_OPEN = 2,       // reader thread failed to start
    WABE_ERR_ACCEL_DEAD = 3, // accel stream dead in this process (sticky) — re-exec for fresh dice
    WABE_ERR_SOCKET = 4,
    WABE_ERR_RECORD = 5,
};

// Runs the daemon: wakes sensors, serves newline-JSON poses on the unix socket, accepts
// "recenter" commands. Blocks forever on success; returns a WABE_ERR_* on setup failure.
int wabe_service_run(const wabe_config *cfg);

#ifdef __cplusplus
}
#endif

#endif
