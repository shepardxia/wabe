// C core for the SPU sensors (BMI286 accel/gyro + lid angle). See NOTES.md for everything
// device-specific; nothing here should need root.
#ifndef WABE_SENSOR_H
#define WABE_SENSOR_H

#include <stddef.h>

typedef struct {
	double t;        // CLOCK_MONOTONIC seconds, stamped at callback delivery
	float x, y, z;   // g for accel, deg/s for gyro
} ws_sample;

// Set AppleSPUHIDDriver properties. interval_us=1000 -> ~795 Hz. Returns number of driver
// services configured (0 means the wake failed everywhere).
int ws_wake(int interval_us);
// Put the sensors back to sleep (ReportingState=0, PowerState=0).
int ws_sleep(void);

// Open accel+gyro and spawn the reader thread. Returns 0 on success.
int ws_start(void);
// Which sensors actually stream after ws_start: bit0 = accel, bit1 = gyro. The accel stream is
// stochastically dead per process (see NOTES.md); callers should re-exec when bit0 is missing.
int ws_opened_mask(void);
void ws_stop(void);

// Drain up to `max` samples into `out`; returns count. Single consumer per sensor.
size_t ws_read_accel(ws_sample *out, size_t max);
size_t ws_read_gyro(ws_sample *out, size_t max);

// Lid angle in degrees at 0.01 resolution (input report 7 -- GetValue is the known trap).
// Synchronous poll on the calling thread; returns negative on error.
double ws_lid_deg(void);

#endif
