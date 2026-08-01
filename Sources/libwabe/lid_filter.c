// Reconstructing the lid angle between hinge samples.
//
// The hinge encoder reports 0.01 degrees, which reads like a precise sensor and is not a fast one:
// measured on Mac16,6, the value changes on a ~100 ms grid (median gap 100.5 ms, p90 104.4, over
// 919 polls at 172 Hz — 17 identical reads per change). Polling harder buys latency and nothing
// else, because there is nothing new to read. Published raw at 120 Hz it is a staircase, and
// anything composing it into the screen normal inherits a staircase: 8.7 degrees of jump in a
// single frame during an ordinary lid pivot.
//
// So the angle is reconstructed rather than held. Two stages, and both earn their place:
//
//   1. An alpha-beta tracker (constant-velocity model, steady-state gains). It predicts forward to
//      whatever time the caller asks for, so the output keeps moving between samples instead of
//      waiting for the next one. This is what removes the lag as well as the steps.
//
//   2. A one-pole stage on its output. Without it the tracker is still not continuous: at each
//      correction the estimate moves by alpha times the prediction residual, which during a fast
//      pivot is degrees, so the staircase comes back at a tenth the height. The pole spreads that
//      correction over tau instead of applying it in one frame.
//
// The gains are derived, not dialled. Kalata's tracking index (IEEE Trans. AES-20, 1984) gives the
// steady-state Kalman gains for this model from two measured numbers:
//
//   sigma_w = 0.031 deg   encoder noise, measured at rest over 51 ticks
//   sigma_a = 50 deg/s^2  process noise: how hard a hand-driven hinge actually accelerates
//   T       = WABE_LID_PERIOD  measured sample period (internal.h)
//
//   lambda = sigma_a T^2 / sigma_w = 16.2
//   r      = (4 + lambda - sqrt(8 lambda + lambda^2)) / 4 = 0.100
//   alpha  = 1 - r^2   = 0.99
//   beta   = 2(2 - alpha) - 4 sqrt(1 - alpha) = 1.62
//
// Simulated against a 35 degree pivot at 87 deg/s, five noise seeds, versus holding the last
// sample. Snap-back is the rate the output travels *backwards* once the hinge has stopped, which
// is the artefact worth spending lag on: a trail reads as weight, a reversal reads as a bug.
//
//                     lag        overshoot   snap-back    step per frame
//   hold (before)     37.5 ms     0.048 deg   8.88 deg/s  8.748   (true motion 0.729)
//   this filter       47.8 ms     0.110 deg   2.23 deg/s  1.021
//
// Eight times less stepping and four times less reversal, for 10 ms of lag. Note the floor:
// predicting across a 100 ms gap at 50 deg/s^2 costs a few tenths of a degree no matter how clever
// the estimator, so this is within small factors of the best any filter can do on a 10 Hz sensor.
// The way past it is a faster hinge sample, not a better filter.
//
// Those gains describe a hinge being moved. Most of the time none is, and the model above has no
// way to say so: sigma_a = 50 deg/s^2 asserts the lid could be accelerating at any instant, so
// every noise sample gets read as a small motion. See the gate at LID_GATE below, which is what
// makes a stationary lid come out quieter than the sensor rather than louder. Measured on a
// stationary hinge, output jitter against the encoder's own 0.036 deg:
//
//                     jitter rms   peak to peak
//   ungated            0.044 deg     0.318 deg    (worse than the sensor)
//   gated              0.010 deg     0.047 deg
#include "internal.h"

#include <math.h>

// Kalata steady-state gains for the numbers above.
#define LID_ALPHA 0.99
#define LID_BETA 1.62
// How long the tracker may extrapolate past its last correction. Past about one sample period the
// constant-velocity model is guessing, and a dropped report should not send the angle flying.
#define LID_HORIZON (1.5 * WABE_LID_PERIOD)
#define LID_TAU 0.050
// How much of the tracked rate the output actually rides.
//
// At 1.0 the constant-velocity model is believed outright, and when the hinge stops it sails past
// and gets hauled back — 7.9 deg/s of backward travel, doubled again by the mirror. A reversal
// reads far worse than a trail: lag looks like weight, snapping back looks like a bug. So the
// extrapolation is deliberately under-trusted. This is the one number to move if it wants to feel
// more eager (up) or calmer (down); everything else here is derived.
//
//   vtrust  lag      overshoot   snap-back
//   1.00    33.0 ms   0.430 deg   7.88 deg/s
//   0.65    47.8 ms   0.110 deg   2.23 deg/s     <- shipped
//   0.50    58.8 ms   0.075 deg   1.37 deg/s
#define LID_VTRUST 0.65

// The hinge is a friction joint. It is exactly stationary unless a hand is bending it, and it
// cannot drift on its own — so a residual the size of the encoder's own noise is evidence of
// nothing, and the constant-velocity model above must not be allowed to read a rate out of it.
// Left ungated it does: a 0.04 deg wiggle becomes a degree per second of estimated rate, the
// output stage extrapolates that across the sample gap, and a lid sitting still on a desk
// reconstructs to nearly twice the jitter of the sensor it came from.
//
// Measured at rest on Mac16,6, the reading is white with sigma 0.036 deg over 34 s, so residuals
// below a few sigma are noise and residuals above are a hand. The two are three orders of
// magnitude apart: a hand pivot is degrees per sample, noise is hundredths.
#define LID_SIGMA 0.0364
#define LID_GATE (3 * LID_SIGMA)
// How much of the position correction survives inside the gate. Not zero: a hinge does settle,
// and a filter that discarded every small residual forever would hold a stale angle. At this
// weight the estimate averages roughly fifty samples, which is what puts the output below its
// own input noise instead of above it.
#define LID_CREEP 0.02

/// How much a residual should be believed to mean motion: nothing inside the noise floor, fully
/// past twice it. Ramped rather than switched, so a slow pivot is not a mode change.
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
    // A poll is not a sample. The encoder answers ~17 times per actual update, and correcting on
    // every one of those drags the velocity estimate to zero — the filter would faithfully track a
    // staircase. Correct on a changed reading, or when the grid says one is due anyway so a lid
    // that has genuinely stopped decays its velocity instead of coasting.
    const double dt = now - f->t;
    if (deg == f->last_raw && dt < WABE_LID_PERIOD)
        return;
    f->last_raw = deg;
    if (dt <= 0)
        return;

    // The true elapsed time, not the clamped horizon: the horizon bounds how far the *output* may
    // be extrapolated, but clamping it here would mis-attribute the residual and corrupt the gains.
    const double predicted = f->x + f->v * dt;
    const double residual = deg - predicted;
    const double w = credence(residual);
    f->x = predicted + LID_ALPHA * (LID_CREEP + (1 - LID_CREEP) * w) * residual;
    if (w > 0) {
        f->v += (LID_BETA / dt) * w * residual;
    } else {
        // Nothing is driving it, so it is not moving. Holding the last rate would coast the
        // output on through a hinge that has already stopped.
        f->v = 0;
    }
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
    // Clamped: a long stall between reads must not hand the pole a weight above 1.
    if (step > 0.25)
        step = 0.25;
    f->y += (1.0 - exp(-step / LID_TAU)) * (raw - f->y);
    f->ty = now;
    return f->y;
}
