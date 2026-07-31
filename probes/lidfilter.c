// Does the lid reconstruction do what lid_filter.c claims? Drives it with a synthetic hinge at the
// real sensor's rate and quantization, with no sensor and no daemon in the way, and prints the
// three numbers the design was chosen on: lag, overshoot, and frame-to-frame step.
//
//   clang -O2 -ISources/libwabe -ISources/libwabe/include -o lidfilter probes/lidfilter.c \
//       Sources/libwabe/lid_filter.c -lm
#include "internal.h"

#include <math.h>
#include <stdio.h>

#define T 0.1005      // measured hinge sample period
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
            // What the encoder would report: quantized to 0.01 deg, on its own slow grid.
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
    // Bounds, not targets: each is well clear of the shipped design point, so this fails on a
    // regression rather than on retuning.
    const int ok = n > 300 && worst_step < 2 * true_step && lag / 87 < 0.075
                   && overshoot < 0.35 && snapback * 120 < 4;
    printf("%s\n", ok ? "ok" : "FAIL");
    return ok ? 0 : 1;
}
