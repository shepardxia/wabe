// Drives lid_filter.c with a synthetic hinge at the encoder's rate and quantization, no sensor
// needed, and prints what the gains were chosen on: lag on a ramp, invented travel after a dead
// stop, and jitter at rest.
//
//   clang -O2 -ISources/libwabe -ISources/libwabe/include -o lidfilter probes/lidfilter.c \
//       Sources/libwabe/lid_filter.c -lm
#include "internal.h"

#include <math.h>
#include <stdio.h>

#define T WABE_LID_PERIOD  // the filter's own constant, so this cannot drift from what it guards
#define PUB (1.0 / WABE_DEFAULT_PUBLISH_HZ)
#define POLL (1.0 / 250)  // drain_loop asks the hinge about this often, far faster than it moves
#define CAP 4096

#define REST_SIGMA 0.0364

static unsigned long seed = 1;
static double gauss(void)
{
    double u1, u2;
    seed = seed * 6364136223846793005UL + 1442695040888963407UL;
    u1 = ((seed >> 11) + 1.0) / 9007199254740993.0;
    seed = seed * 6364136223846793005UL + 1442695040888963407UL;
    u2 = (double)(seed >> 11) / 9007199254740992.0;
    return sqrt(-2 * log(u1)) * cos(2 * M_PI * u2);
}

typedef struct {
    double t, truth, out, rate;
} frame;

/// Degrees by which the output left the range of readings the encoder had actually delivered.
/// The reconstruction interpolates between measured anchors and never past the newest, so this is
/// zero by construction and any other value means the filter is publishing an angle nothing
/// measured. Every case checks it, because it is the property, not a symptom of one trajectory.
static double lead;

/// Runs a hinge trajectory past the filter the way the daemon does: polled far faster than the
/// encoder refreshes, quantized to 0.01 deg on the encoder's grid, read back at the publish rate.
/// Every case measures the same object this way, so a case cannot accidentally test a different
/// filter than the others.
static int drive(double (*truth)(double), int noisy, double span, frame *out)
{
    wabe_lid_filter f;
    wabe_lid_filter_reset(&f);
    double next_sample = 0, next_pub = 0, held = 0;
    double seen_lo = 1e9, seen_hi = -1e9;
    int n = 0;

    lead = 0;
    for (double t = 0; t < span && n < CAP; t += POLL) {
        if (t >= next_sample) {
            const double d = truth(t) + (noisy ? REST_SIGMA * gauss() : 0.0);
            held = round(d * 100.0) / 100.0;
            next_sample += T;
            if (held < seen_lo) seen_lo = held;
            if (held > seen_hi) seen_hi = held;
        }
        wabe_lid_filter_push(&f, held, t);
        if (t < next_pub)
            continue;
        next_pub += PUB;
        const double v = wabe_lid_filter_value(&f, t);
        if (v < 0)
            continue;
        if (v - seen_hi > lead) lead = v - seen_hi;
        if (seen_lo - v > lead) lead = seen_lo - v;
        out[n] = (frame){ t, truth(t), v, n ? (v - out[n - 1].out) / PUB : 0.0 };
        n++;
    }
    return n;
}

// ---------------------------------------------------------------- ramp: does it keep up

static double ramp_truth(double t)
{
    // A 35 degree pivot out and back, smoothstepped, peaking near 87 deg/s.
    double u;
    if (t < 0.5) return 108.0;
    if (t < 1.1) { u = (t - 0.5) / 0.6; return 108.0 + 35.0 * u * u * (3 - 2 * u); }
    if (t < 1.9) return 143.0;
    if (t < 2.5) { u = (t - 1.9) / 0.6; return 143.0 - 35.0 * u * u * (3 - 2 * u); }
    return 108.0;
}

static int ramp_case(frame *f)
{
    const int n = drive(ramp_truth, 0, 3.2, f);
    // Mean error across the ramps, which is the statistic the gains were chosen on. Worst-case is
    // also tracked, but it is dominated by the acceleration onset and says little about feel.
    double lag_sum = 0, worst_lag = 0, worst_step = 0, true_step = 0;
    int lag_n = 0;

    for (int i = 1; i < n; i++) {
        const double step = fabs(f[i].out - f[i - 1].out);
        if (step > worst_step) worst_step = step;
        const double ts = fabs(f[i].truth - f[i - 1].truth);
        if (ts > true_step) true_step = ts;
        const double err = fabs(f[i].out - f[i].truth);
        if ((f[i].t > 0.55 && f[i].t < 1.05) || (f[i].t > 1.95 && f[i].t < 2.45)) {
            if (err > worst_lag) worst_lag = err;
            lag_sum += err;
            lag_n++;
        }
    }
    const double lag = lag_n ? lag_sum / lag_n : 0;
    printf("-- 87 deg/s pivot, smoothstepped, %d published frames --\n", n);
    printf("lag                %.3f deg  (%.0f ms at 87 deg/s)   worst %.2f deg\n",
           lag, lag / 87 * 1000, worst_lag);
    printf("step per frame     %.3f deg   (true motion %.3f)\n", worst_step, true_step);
    printf("led the encoder    %.4f deg\n", lead);
    // Nothing here may overshoot a frame of true motion, and the delay may not exceed the one
    // period the reconstruction is defined to sit behind, with a frame of publish grid on top.
    const int ok = n > 90 && lead == 0.0 && worst_step < 1.6 * true_step
                   && lag / 87 < T + PUB;
    printf("%s\n", ok ? "ok" : "FAIL");
    return ok;
}

// ---------------------------------------------------------- dead stop: does it stop with it

#define STOP_RATE 40.0
#define STOP_BEGIN 0.30
#define STOP_AT 1.00
#define STOP_SPAN 2.2

/// A hand pushing the lid at a steady rate and letting go. The hinge is a friction joint, so
/// release is a dead stop, not a decelerating one — the case a smoothstepped ramp never poses.
static double stop_truth(double t)
{
    if (t < STOP_BEGIN) return 108.0;
    if (t < STOP_AT) return 108.0 + STOP_RATE * (t - STOP_BEGIN);
    return 108.0 + STOP_RATE * (STOP_AT - STOP_BEGIN);
}

static int stop_case(frame *f)
{
    const int n = drive(stop_truth, 0, STOP_SPAN, f);
    const double final = stop_truth(STOP_SPAN);
    // Sampled after the onset transient has passed, while the hand is still moving at one rate.
    double steady_lo = 1e9, steady_hi = -1e9, err_sum = 0;
    double overshoot = 0, variation = 0, settle = 0, first = 0, last = 0;
    int reversals = 0, sign = 0, started = 0, err_n = 0;

    for (int i = 1; i < n; i++) {
        if (f[i].t > 0.6 && f[i].t < STOP_AT) {
            if (f[i].rate < steady_lo) steady_lo = f[i].rate;
            if (f[i].rate > steady_hi) steady_hi = f[i].rate;
            err_sum += f[i].truth - f[i].out;
            err_n++;
        }
        if (f[i].t < STOP_AT)
            continue;
        if (!started) { started = 1; first = f[i - 1].out; }
        last = f[i].out;
        if (f[i].out - final > overshoot) overshoot = f[i].out - final;
        variation += fabs(f[i].out - f[i - 1].out);
        if (fabs(f[i].rate) >= 2.0) settle = f[i].t - STOP_AT;
        // Deadbanded so encoder quantization cannot manufacture a direction change.
        const int s = f[i].rate > 1.0 ? 1 : (f[i].rate < -1.0 ? -1 : 0);
        if (s && sign && s != sign) reversals++;
        if (s) sign = s;
    }
    const double sawtooth = steady_hi / steady_lo;
    // Total variation less the net displacement: the ground the output covers twice. Catching up
    // from wherever the lag left it is owed, so only the doubling back counts as invented.
    const double excess = variation - fabs(last - first);

    const double delay = err_n ? err_sum / err_n / STOP_RATE : 0;

    printf("\n-- %g deg/s pivot released at t=%.2f, %d published frames --\n", STOP_RATE, STOP_AT, n);
    printf("steady-motion rate %.1f..%.1f deg/s   sawtooth %.2fx  (true %.1f)\n",
           steady_lo, steady_hi, sawtooth, STOP_RATE);
    printf("delay              %.0f ms       (%.2f encoder periods)\n", delay * 1000, delay / T);
    printf("overshoot          %.3f deg\n", overshoot);
    printf("direction changes  %d          after the hinge is already still\n", reversals);
    printf("settle to <2 deg/s %.0f ms      (%.1f encoder periods)\n", settle * 1000, settle / T);
    printf("invented travel    %.3f deg\n", excess);
    printf("led the encoder    %.4f deg\n", lead);
    // The reconstruction interpolates between measured anchors, so it cannot overrun a stop, cannot
    // reverse a direction the hinge did not, and cannot lead the encoder — those are zero, not
    // small. What it costs is delay, and that must be the one period it is defined to be, no more.
    // Delay is only resolved to the grid the output is read on, so one publish frame is the
    // tightest this can be asserted; it is there to catch a design that drifts to two periods.
    const int ok = lead == 0.0 && overshoot == 0.0 && excess == 0.0 && reversals == 0
                   && fabs(delay - T) <= PUB && settle <= T + 2 * PUB && sawtooth < 1.5;
    printf("%s\n", ok ? "ok" : "FAIL");
    return ok;
}

// ------------------------------------------------------------------ rest: does it sit still

/// What the output does while nothing is moving it. The hinge is a friction joint: it is exactly
/// stationary unless a hand is bending it, so every degree of travel here is invented.
static double rest_truth(double t) { (void)t; return 108.0; }

static int rest_case(frame *f)
{
    const int n = drive(rest_truth, 1, 40.0, f);
    double lo = 1e9, hi = -1e9, sum = 0, sum2 = 0;
    int m = 0;

    for (int i = 0; i < n; i++) {
        if (f[i].t < 2.0) continue;  // let it prime
        const double e = f[i].out - 108.0;
        if (f[i].out < lo) lo = f[i].out;
        if (f[i].out > hi) hi = f[i].out;
        sum += e;
        sum2 += e * e;
        m++;
    }
    const double rms = sqrt(sum2 / m);
    const double bias = sum / m;
    printf("\n-- at rest, %d published frames over 38 s --\n", m);
    printf("input noise        %.4f deg rms  (measured encoder, white)\n", REST_SIGMA);
    printf("output jitter      %.4f deg rms   p2p %.3f deg\n", rms, hi - lo);
    printf("bias               %+.4f deg\n", bias);
    printf("vs raw encoder     %.2fx\n", rms / REST_SIGMA);
    printf("led the encoder    %.4f deg\n", lead);
    const int ok = lead == 0.0 && rms < REST_SIGMA && (hi - lo) < 0.15 && fabs(bias) < 0.01;
    printf("%s\n", ok ? "ok" : "FAIL");
    return ok;
}

int main(void)
{
    static frame f[CAP];
    const int a = ramp_case(f);
    const int b = stop_case(f);
    const int c = rest_case(f);
    return (a && b && c) ? 0 : 1;
}
