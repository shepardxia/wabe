// SPDX-License-Identifier: MIT
#include "vqf.hpp"
#include "wabe_vqf.h"

struct wvqf {
    VQF vqf;
    explicit wvqf(double gyrTs) : vqf(gyrTs) {}
};

extern "C" {

wvqf *wvqf_create(double gyrTs) { return new wvqf(gyrTs); }

void wvqf_destroy(wvqf *v) { delete v; }

void wvqf_update(wvqf *v, const double gyr[3], const double acc[3])
{
    v->vqf.updateGyr(gyr);
    v->vqf.updateAcc(acc);
}

void wvqf_quat6d(const wvqf *v, double out[4]) { v->vqf.getQuat6D(out); }

void wvqf_bias(const wvqf *v, double out[3]) { v->vqf.getBiasEstimate(out); }

int wvqf_rest(const wvqf *v) { return v->vqf.getRestDetected() ? 1 : 0; }

}  // extern "C"
