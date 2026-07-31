// libwabe: orientation for Apple Silicon MacBooks, including the screen plane.
//
//   wabe *w = wabe_start(NULL, NULL);   // opens the sensors, tracks in the background
//   wabe_orientation o;
//   wabe_read(w, &o);                   // latest orientation, any thread
//   wabe_stop(w);
//
// wabe_serve() runs the same thing as a socket daemon. wabe_replay() is for recorded samples.
#ifndef WABE_H
#define WABE_H

#include <dispatch/dispatch.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    double t;       // CLOCK_MONOTONIC seconds of the most recent sample
    double q[4];    // base -> world quaternion (w, x, y, z); base: X right, Y hinge, Z up
    double rpy[3];  // degrees; roll and pitch absolute, yaw relative to the last recenter
    double n[3];    // screen-plane normal in world frame: where the display points
    double lid_deg; // hinge angle, or -1 before the first reading
    double bias[3]; // gyroscope bias estimate, deg/s
    int at_rest;
} wabe_orientation;

// Native IMU rate at ReportInterval=1000 µs, measured. Everything that needs a default sample
// rate takes it from here.
#define WABE_DEFAULT_SENSOR_HZ 795

typedef struct {
    int sensor_hz;           // 0 -> WABE_DEFAULT_SENSOR_HZ
    const char *record_path; // NULL -> no capture; else raw samples written as JSONL
    // Skip the SPU wake sequence; the sensors must already be streaming. Only useful to a harness
    // driving a machine another process has already woken.
    int skip_wake;
} wabe_options;

enum {
    WABE_OK = 0,
    WABE_ERR_WAKE = 1,       // no AppleSPUHIDDriver service accepted the wake properties
    WABE_ERR_OPEN = 2,       // sensor reader failed to start
    WABE_ERR_ACCEL_DEAD = 3, // accelerometer stream dead in this process; re-exec for fresh dice
    WABE_ERR_SOCKET = 4,
    WABE_ERR_RECORD = 5,
    WABE_ERR_GYRO_DEAD = 6,  // gyroscope stream dead; the estimate cannot advance without it
    WABE_ERR_LAYOUT = 7,     // reports arrive but no offset yields a 1 g magnitude
};

typedef struct wabe wabe;

// Open the sensors and track orientation on a background thread. cfg may be NULL for defaults.
// Returns NULL on failure, writing a WABE_ERR_* to err if err is non-NULL.
//
// The IMU and the hinge encoder are separate parts with separate model coverage: a 13-inch Pro
// has no hinge encoder, so it yields orientation but no screen normal. A machine without one is
// not an error; o.lid_deg reads -1 and o.n stays zero, which is how you tell.
wabe *wabe_start(const wabe_options *cfg, int *err);

// Latest orientation. Safe from any thread while tracking runs. Pull it when you need it: a
// renderer wants the newest value at vsync, not a backlog.
void wabe_read(wabe *w, wabe_orientation *out);

// Make the current heading the zero of this handle's relative yaw.
void wabe_recenter(wabe *w);

// Yaw of `q` about vertical relative to reference attitude `ref`, in degrees. Hold your own
// `ref` (a previously read o.q) and you get a heading zero nobody else can move.
double wabe_relative_yaw(const double q[4], const double ref[4]);

// Stop tracking, release the sensors, free the handle.
void wabe_stop(wabe *w);

// --- daemon ---

typedef struct {
    wabe_options sensors;
    double publish_hz;       // 0 -> 30
    const char *socket_path; // NULL -> /tmp/wabe.sock
} wabe_service;

// Serve orientation as newline JSON on a unix socket, accepting "recenter" from clients.
// Blocks; returns a WABE_ERR_* only on setup failure.
int wabe_serve(const wabe_service *cfg);

// --- recorded samples ---
//
// The same tracker without the sensors attached, so a capture can be replayed through exactly
// what the daemon runs. One sample in the chip frame: g for accelerometer, deg/s for gyroscope,
// CLOCK_MONOTONIC seconds. Axis correction to the base frame happens inside.

typedef struct {
    double t;
    double v[3];
} wabe_sample;

wabe *wabe_replay(double sample_hz);

// Feed a batch. Both arrays must ascend in time; gyroscope samples drive the estimate and
// accelerometer samples correct it, so they need not be aligned or equal in length.
void wabe_feed(wabe *w, const wabe_sample *accel, size_t n_accel,
               const wabe_sample *gyro, size_t n_gyro);

// Hinge angle in degrees. Only the screen normal needs it; wabe_start() polls it for you.
//
// The reading is stamped at the handle's present, which on a replay handle is the timestamp of the
// last sample fed. Feed up to a recorded hinge reading's moment before pushing it, or the
// reconstruction dates it wrong.
void wabe_set_lid(wabe *w, double deg);

#ifdef __cplusplus
}
#endif

#endif
