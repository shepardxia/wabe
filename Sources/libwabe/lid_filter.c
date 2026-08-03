// Reconstructs the lid angle between hinge samples. Measurements in NOTES.md.
//
// The encoder is exact and slow: it hands over the true angle every WABE_LID_PERIOD and says
// nothing in between. Anything published ahead of the newest anchor is therefore invented, and a
// friction hinge punishes that — it stops dead, so an extrapolator is always still moving when the
// lid already stopped, and has to double back. So this does not extrapolate. It runs one period
// behind and interpolates between the two anchors bracketing the output time, which bounds the
// output inside two measured values by construction: it cannot overrun a stop, cannot reverse
// direction the hinge did not reverse, and holds no state that outlives the anchors it came from.
//
// The cost is stated plainly: the output reaches an angle one encoder period after the hinge does.
#include "internal.h"

#include <math.h>

/// How far behind the reconstruction runs. One period is the minimum that always has an anchor on
/// both sides of the output time; less than that is extrapolation wearing a different name.
#define LID_DELAY WABE_LID_PERIOD

// Measured encoder noise at rest: white, sigma 0.036 deg.
#define LID_SIGMA 0.0364
#define LID_GATE (3 * LID_SIGMA)
/// Anchor correction surviving inside the gate, tracking a hinge settling too slowly to clear it.
#define LID_CREEP 0.02

/// Belief that a change between anchors is motion: zero inside the noise floor, full past twice
/// it. Denoising happens here, on the anchors, so that the span between them stays exact.
static double credence(double change)
{
    const double a = fabs(change);
    if (a <= LID_GATE)
        return 0.0;
    if (a >= 2 * LID_GATE)
        return 1.0;
    return (a - LID_GATE) / LID_GATE;
}

/// Slope at an anchor with a measured neighbour on each side, limited so the cubic through them
/// cannot leave the interval: an extremum flattens, and no slope exceeds three times the smaller
/// secant. Fritsch and Carlson, SIAM J. Numer. Anal. 17 (1980).
static double slope(double back, double fwd, double h_back, double h_fwd)
{
    if (back * fwd <= 0)
        return 0.0;
    const double w_back = 2 * h_fwd + h_back;
    const double w_fwd = h_fwd + 2 * h_back;
    return (w_back + w_fwd) / (w_back / back + w_fwd / fwd);
}

void wabe_lid_filter_reset(wabe_lid_filter *f)
{
    f->n = 0;
    f->last_raw = -1;
    for (int i = 0; i < WABE_LID_ANCHORS; i++)
        f->t[i] = f->a[i] = 0;
}

void wabe_lid_filter_push(wabe_lid_filter *f, double deg, double now)
{
    if (deg < 0)
        return;
    if (f->n == 0) {
        f->t[0] = now;
        f->a[0] = deg;
        f->n = 1;
        f->last_raw = deg;
        return;
    }
    // A repeated reading is not a new anchor until the grid says one was due; at rest the encoder
    // can sit on a value indefinitely, and the reconstruction still needs anchors to span.
    if (deg == f->last_raw && now - f->t[0] < WABE_LID_PERIOD)
        return;
    if (now <= f->t[0])
        return;
    f->last_raw = deg;

    // At rest successive readings differ by noise, and interpolating through that would publish
    // it. Past the gate the reading is taken exactly, so a real pivot lands on its measured angle.
    const double change = deg - f->a[0];
    const double w = credence(change);
    const double anchor = f->a[0] + (LID_CREEP + (1 - LID_CREEP) * w) * change;

    for (int i = WABE_LID_ANCHORS - 1; i > 0; i--) {
        f->t[i] = f->t[i - 1];
        f->a[i] = f->a[i - 1];
    }
    f->t[0] = now;
    f->a[0] = anchor;
    if (f->n < WABE_LID_ANCHORS)
        f->n++;
}

double wabe_lid_filter_value(const wabe_lid_filter *f, double now)
{
    if (f->n == 0)
        return -1;
    const double target = now - LID_DELAY;
    // Outside the measured span there is nothing to interpolate, so hold the endpoint. Holding is
    // the only honest answer here and the reason the output can never lead the hinge.
    if (f->n == 1 || target >= f->t[0])
        return f->a[0];
    if (target <= f->t[f->n - 1])
        return f->a[f->n - 1];

    int j = 0;  // target lies in [t[j+1], t[j]]
    while (j + 1 < f->n - 1 && target < f->t[j + 1])
        j++;

    const double h = f->t[j] - f->t[j + 1];
    if (h <= 0)
        return f->a[j];
    const double d = (f->a[j] - f->a[j + 1]) / h;

    // Centred slopes wherever a third anchor exists on that side; at the newest anchor none does,
    // and the span's own secant is the estimate that cannot overshoot.
    double m_new = d, m_old = d;
    if (j > 0) {
        const double h_new = f->t[j - 1] - f->t[j];
        m_new = slope(d, (f->a[j - 1] - f->a[j]) / h_new, h, h_new);
    }
    if (j + 2 < f->n) {
        const double h_old = f->t[j + 1] - f->t[j + 2];
        m_old = slope((f->a[j + 1] - f->a[j + 2]) / h_old, d, h_old, h);
    }

    const double u = (target - f->t[j + 1]) / h;
    const double u2 = u * u, u3 = u2 * u;
    return f->a[j + 1] * (2 * u3 - 3 * u2 + 1) + f->a[j] * (-2 * u3 + 3 * u2)
           + m_old * h * (u3 - 2 * u2 + u) + m_new * h * (u3 - u2);
}
