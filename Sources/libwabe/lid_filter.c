// Reconstructs the lid angle between hinge samples. Alpha-beta tracker extrapolating to the read
// time, then a one-pole stage. Gains are Kalata's tracking index (IEEE Trans. AES-20, 1984) for
// sigma_w 0.031 deg, sigma_a 50 deg/s^2, T = WABE_LID_PERIOD. Measurements in NOTES.md.
#include "internal.h"

#include <math.h>

#define LID_ALPHA 0.99
#define LID_BETA 1.62
#define LID_HORIZON (1.5 * WABE_LID_PERIOD)
#define LID_TAU 0.050
// Fraction of the tracked rate the output rides. The one number here to change for feel.
#define LID_VTRUST 0.65

// Measured encoder noise at rest: white, sigma 0.036 deg.
#define LID_SIGMA 0.0364
#define LID_GATE (3 * LID_SIGMA)
// Position correction surviving inside the gate, tracking a settling hinge.
#define LID_CREEP 0.02

/// Belief that a residual means motion: zero inside the noise floor, full past twice it.
static double credence(double residual)
{
    const double a = fabs(residual);
    if (a <= LID_GATE)
        return 0.0;
    if (a >= 2 * LID_GATE)
        return 1.0;
    return (a - LID_GATE) / LID_GATE;
}

void wabe_lid_filter_reset(wabe_lid_filter *f)
{
    f->primed = 0;
    f->x = f->v = 0;
    f->t = f->ty = 0;
    f->y = 0;
    f->last_raw = -1;
}

void wabe_lid_filter_push(wabe_lid_filter *f, double deg, double now)
{
    if (deg < 0)
        return;
    if (!f->primed) {
        f->primed = 1;
        f->x = f->y = deg;
        f->v = 0;
        f->t = f->ty = now;
        f->last_raw = deg;
        return;
    }
    // Correct on a changed reading, or when the grid says one was due.
    const double dt = now - f->t;
    if (deg == f->last_raw && dt < WABE_LID_PERIOD)
        return;
    f->last_raw = deg;
    if (dt <= 0)
        return;

    const double predicted = f->x + f->v * dt;
    const double residual = deg - predicted;
    const double w = credence(residual);
    f->x = predicted + LID_ALPHA * (LID_CREEP + (1 - LID_CREEP) * w) * residual;
    f->v = w > 0 ? f->v + (LID_BETA / dt) * w * residual : 0;
    f->t = now;
}

double wabe_lid_filter_value(wabe_lid_filter *f, double now)
{
    if (!f->primed)
        return -1;
    const double ahead = now - f->t;
    const double horizon = ahead < LID_HORIZON ? (ahead > 0 ? ahead : 0) : LID_HORIZON;
    const double raw = f->x + f->v * LID_VTRUST * horizon;

    double step = now - f->ty;
    if (step <= 0)
        return f->y;
    if (step > 0.25)
        step = 0.25;
    f->y += (1.0 - exp(-step / LID_TAU)) * (raw - f->y);
    f->ty = now;
    return f->y;
}
