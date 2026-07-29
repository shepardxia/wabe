// C shim over the vendored VQF C++ implementation (Sources/CWabeVQF/vendor, MIT,
// D. Laidig & T. Seel — "VQF: Highly Accurate IMU Orientation Estimation", Inf. Fusion 2023).
#ifndef WABE_VQF_H
#define WABE_VQF_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct wvqf wvqf;

// gyrTs: sampling period in seconds (VQF assumes uniform sampling).
wvqf *wvqf_create(double gyrTs);
void wvqf_destroy(wvqf *v);

// One fused step: gyroscope in rad/s, accelerometer in m/s^2 (sensor frame).
void wvqf_update(wvqf *v, const double gyr[3], const double acc[3]);

// 6D orientation quaternion (w, x, y, z), sensor frame -> earth frame (z up, heading arbitrary).
void wvqf_quat6d(const wvqf *v, double out[4]);

// Current gyroscope bias estimate, rad/s.
void wvqf_bias(const wvqf *v, double out[3]);

// Nonzero while VQF's rest detection considers the sensor at rest.
int wvqf_rest(const wvqf *v);

#ifdef __cplusplus
}
#endif

#endif
