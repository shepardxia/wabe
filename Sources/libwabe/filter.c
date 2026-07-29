// Filter core: chip->base axis maps, timestamp merge, VQF (via the C shim over the vendored
// C++), heading reference, and pose extraction. Pure computation — no I/O.
#include "include/wabe.h"
#include "vendor/wabe_vqf.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#define DEG2RAD (M_PI / 180.0)
#define RAD2DEG (180.0 / M_PI)
#define G_TO_MS2 9.80665

struct wabe_filter {
    wvqf *vqf;
    double q[4];    // base -> world, w x y z
    double ref[4];  // heading reference (recenter)
    double bias[3]; // rad/s
    int rest;
    double last_accel[3]; // base frame, g (zero-order hold)
    int have_accel;
    double lid_deg;
    int first;
};

// Chip->base axis maps, measured on Mac16,6 (see NOTES.md): the readout triad is left-handed
// (chip +x = laptop left, +y = front, +z = down). Accel (true vector) maps by full negation;
// gyro (pseudo-vector) maps by identity, so gyro samples are used as-is below.
static void accel_chip_to_base(const double v[3], double out[3])
{
    out[0] = -v[0];
    out[1] = -v[1];
    out[2] = -v[2];
}

// q multiply, (w,x,y,z)
static void quat_mul(const double a[4], const double b[4], double out[4])
{
    out[0] = a[0] * b[0] - a[1] * b[1] - a[2] * b[2] - a[3] * b[3];
    out[1] = a[0] * b[1] + a[1] * b[0] + a[2] * b[3] - a[3] * b[2];
    out[2] = a[0] * b[2] - a[1] * b[3] + a[2] * b[0] + a[3] * b[1];
    out[3] = a[0] * b[3] + a[1] * b[2] - a[2] * b[1] + a[3] * b[0];
}

static void quat_conj(const double q[4], double out[4])
{
    out[0] = q[0];
    out[1] = -q[1];
    out[2] = -q[2];
    out[3] = -q[3];
}

// Row-major rotation matrix of a unit quaternion (base->world).
static void quat_to_mat(const double q[4], double m[3][3])
{
    const double w = q[0], x = q[1], y = q[2], z = q[3];
    m[0][0] = 1 - 2 * (y * y + z * z);
    m[0][1] = 2 * (x * y - w * z);
    m[0][2] = 2 * (x * z + w * y);
    m[1][0] = 2 * (x * y + w * z);
    m[1][1] = 1 - 2 * (x * x + z * z);
    m[1][2] = 2 * (y * z - w * x);
    m[2][0] = 2 * (x * z - w * y);
    m[2][1] = 2 * (y * z + w * x);
    m[2][2] = 1 - 2 * (x * x + y * y);
}

wabe_filter *wabe_filter_new(double sample_hz)
{
    wabe_filter *f = calloc(1, sizeof(*f));
    if (!f)
        return NULL;
    f->vqf = wvqf_create(1.0 / (sample_hz > 0 ? sample_hz : 795.0));
    f->q[0] = 1;
    f->ref[0] = 1;
    f->lid_deg = -1;
    f->first = 1;
    return f;
}

void wabe_filter_free(wabe_filter *f)
{
    if (!f)
        return;
    wvqf_destroy(f->vqf);
    free(f);
}

static void filter_update(wabe_filter *f, const double gyro_chip[3])
{
    double gyr[3], acc[3];
    for (int i = 0; i < 3; i++) {
        gyr[i] = gyro_chip[i] * DEG2RAD;  // gyro base frame == chip frame
        acc[i] = f->last_accel[i] * G_TO_MS2;
    }
    wvqf_update(f->vqf, gyr, acc);
    wvqf_quat6d(f->vqf, f->q);
    wvqf_bias(f->vqf, f->bias);
    f->rest = wvqf_rest(f->vqf);
    if (f->first) {
        f->first = 0;
        memcpy(f->ref, f->q, sizeof(f->ref));
    }
}

void wabe_filter_feed(wabe_filter *f, const wabe_sample *accel, size_t na,
                      const wabe_sample *gyro, size_t ng)
{
    size_t ai = 0;
    for (size_t gi = 0; gi < ng; gi++) {
        while (ai < na && accel[ai].t <= gyro[gi].t) {
            accel_chip_to_base(accel[ai].v, f->last_accel);
            f->have_accel = 1;
            ai++;
        }
        if (f->have_accel)
            filter_update(f, gyro[gi].v);
    }
    while (ai < na) {
        accel_chip_to_base(accel[ai].v, f->last_accel);
        f->have_accel = 1;
        ai++;
    }
}

void wabe_filter_set_lid(wabe_filter *f, double deg) { f->lid_deg = deg; }

void wabe_filter_recenter(wabe_filter *f) { memcpy(f->ref, f->q, sizeof(f->ref)); }

void wabe_filter_pose(const wabe_filter *f, double t, wabe_pose *out)
{
    memset(out, 0, sizeof(*out));
    out->t = t;
    memcpy(out->q, f->q, sizeof(out->q));
    for (int i = 0; i < 3; i++)
        out->bias[i] = f->bias[i] * RAD2DEG;
    out->stationary = f->rest;
    out->lid_deg = f->lid_deg;

    // Laptop-intuitive angles. Roll/pitch absolute (gravity), yaw relative to the last
    // recenter. Signs: pitch + = front edge up, roll + = right side down, yaw + = CCW from
    // above.
    double m[3][3];
    quat_to_mat(f->q, m);
    const double about_x = atan2(m[2][1], m[2][2]); // about base X (left-right axis)
    const double about_y = -asin(fmax(-1.0, fmin(1.0, m[2][0]))); // about base Y (front-back)

    double ref_inv[4], rel[4], mrel[3][3];
    quat_conj(f->ref, ref_inv);
    quat_mul(ref_inv, f->q, rel);
    quat_to_mat(rel, mrel);
    const double yaw = atan2(mrel[1][0], mrel[0][0]);

    out->rpy[0] = about_y * RAD2DEG;
    out->rpy[1] = -about_x * RAD2DEG;
    out->rpy[2] = yaw * RAD2DEG;

    // Screen normal: base attitude ⊕ lid angle. Hinge axis = base +X; at lid angle L the
    // face normal in base frame is (0,0,1) rotated about X by (180-L) degrees.
    if (f->lid_deg >= 0) {
        const double theta = (180.0 - f->lid_deg) * DEG2RAD;
        const double nb[3] = {0, -sin(theta), cos(theta)};
        out->n[0] = m[0][0] * nb[0] + m[0][1] * nb[1] + m[0][2] * nb[2];
        out->n[1] = m[1][0] * nb[0] + m[1][1] * nb[1] + m[1][2] * nb[2];
        out->n[2] = m[2][0] * nb[0] + m[2][1] * nb[1] + m[2][2] * nb[2];
    }
}
