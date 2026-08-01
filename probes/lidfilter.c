// Does the lid reconstruction do what lid_filter.c claims? Drives it with a synthetic hinge at the
// real sensor's rate and quantization, with no sensor and no daemon in the way, and prints the
// three numbers the design was chosen on: lag, overshoot, and frame-to-frame step.
#include "internal.h"

#include <math.h>
#include <stdio.h>

#define T WABE_LID_PERIOD  // the filter's own constant, so this cannot drift from what it guards
#define PUB (1.0 / 120)
#define SPAN 3.2

static double truth(double t)
{
    // A 35 degree pivot out and back, smoothstepped, peaking near 87 deg/s.
    double u;
    if (t < 0.5) return 108.0;
    if (t < 1.1) { u = (t - 0.5) / 0.6; return 108.0 + 35.0 * u * u * (3 - 2 * u); }
    if (t < 1.9) return 143.0;
    if (t < 2.5) { u = (t - 1.9) / 0.6; return 143.0 - 35.0 * u * u * (3 - 2 * u); }
    return 108.0;
}

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

/// What the output does while nothing is moving it. The hinge is a friction joint: it is exactly
/// stationary unless a hand is bending it, so every degree of travel here is invented.
static int rest_case(void)
{
    wabe_lid_filter f;
    wabe_lid_filter_reset(&f);
    const double held_true = 108.0;
    double next_sample = 0, held = held_true;
    double lo = 1e9, hi = -1e9, sum = 0, sum2 = 0;
    int n = 0;

    for (double t = 0; t < 40.0; t += PUB) {
        if (t >= next_sample) {
            held = round((held_true + REST_SIGMA * gauss()) * 100.0) / 100.0;
            next_sample += T;
        }
        wabe_lid_filter_push(&f, held, t);
        wabe_lid_filter_push(&f, held, t);
        const double out = wabe_lid_filter_value(&f, t);
        if (out < 0 || t < 2.0) continue;  // let it prime
        if (out < lo) lo = out;
        if (out > hi) hi = out;
        sum += out - held_true;
        sum2 += (out - held_true) * (out - held_true);
        n++;
    }
    const double rms = sqrt(sum2 / n);
    const double bias = sum / n;
    printf("\n-- at rest, %d samples over 38 s --\n", n);
    printf("input noise        %.4f deg rms  (measured encoder, white)\n", REST_SIGMA);
    printf("output jitter      %.4f deg rms   p2p %.3f deg\n", rms, hi - lo);
    printf("bias               %+.4f deg\n", bias);
    printf("vs raw encoder     %.2fx\n", rms / REST_SIGMA);
    const int ok = rms < REST_SIGMA && (hi - lo) < 0.15 && fabs(bias) < 0.01;
    printf("%s\n", ok ? "ok" : "FAIL");
    return ok;
}

int main(void)
{
    wabe_lid_filter f;
    wabe_lid_filter_reset(&f);

    double next_sample = 0, held = truth(0);
    double prev_out = 0, worst_step = 0, worst_lag = 0, overshoot = 0, true_step = 0, snapback = 0;
    // Mean error across the ramps, which is the statistic the gains were chosen on. Worst-case is
    // also tracked, but it is dominated by the acceleration onset and says little about feel.
    double lag_sum = 0;
    int lag_n = 0, n = 0;

    for (double t = 0; t < SPAN; t += PUB) {
        if (t >= next_sample) {
            held = round(truth(t) * 100.0) / 100.0;
            next_sample += T;
        }
        // The daemon polls far faster than the encoder updates, so feed the repeat too: rejecting
        // repeats is the filter's job and this is where that gets exercised.
        wabe_lid_filter_push(&f, held, t);
        wabe_lid_filter_push(&f, held, t);
        const double out = wabe_lid_filter_value(&f, t);
        if (out < 0) continue;

        if (n++ > 0) {
            const double step = fabs(out - prev_out);
            if (step > worst_step) worst_step = step;
        }
        const double ts = fabs(truth(t) - truth(t > PUB ? t - PUB : 0));
        if (ts > true_step) true_step = ts;
        const double err = fabs(out - truth(t));
        if ((t > 0.55 && t < 1.05) || (t > 1.95 && t < 2.45)) {
            if (err > worst_lag) worst_lag = err;
            lag_sum += err;
            lag_n++;
        }
        if (t > 1.15 && t < 1.9) {
            if (out - 143.0 > overshoot) overshoot = out - 143.0;
            // Backward travel once the hinge has stopped: the artefact that reads as a bug.
            if (n > 1 && prev_out - out > snapback) snapback = prev_out - out;
        }
        prev_out = out;
    }

    printf("samples produced   %d\n", n);
    const double lag = lag_n ? lag_sum / lag_n : 0;
    printf("lag                %.3f deg  (%.0f ms at 87 deg/s)   worst %.2f deg\n",
           lag, lag / 87 * 1000, worst_lag);
    printf("overshoot          %.3f deg\n", overshoot);
    printf("snap-back          %.3f deg/s\n", snapback * 120);
    printf("step per frame     %.3f deg   (true motion %.3f)\n", worst_step, true_step);
    const int ok = n > 300 && worst_step < 2 * true_step && lag / 87 < 0.075
                   && overshoot < 0.35 && snapback * 120 < 4;
    printf("%s\n", ok ? "ok" : "FAIL");
    return (ok && rest_case()) ? 0 : 1;
}
