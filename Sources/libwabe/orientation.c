// Orientation core: chip-to-base axis maps, timestamp merge, VQF (via the C shim over the
// C++ in third_party/), heading reference, and angle extraction. Pure computation, no I/O.
#include "internal.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#define DEG2RAD (M_PI / 180.0)
#define RAD2DEG (180.0 / M_PI)
#define G_TO_MS2 9.80665

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

wabe *wabe_replay(double sample_hz)
{
    wabe *w = calloc(1, sizeof(*w));
    if (!w)
        return NULL;
    w->vqf = wvqf_create(1.0 / (sample_hz > 0 ? sample_hz : WABE_DEFAULT_SENSOR_HZ));
    w->q[0] = 1;
    w->ref[0] = 1;
    wabe_lid_filter_reset(&w->lid);
    w->first = 1;
    pthread_mutex_init(&w->lock, NULL);
    return w;
}

static void advance(wabe *w, const double gyro_chip[3])
{
    double gyr[3], acc[3];
    for (int i = 0; i < 3; i++) {
        gyr[i] = gyro_chip[i] * DEG2RAD;  // gyro base frame == chip frame
        acc[i] = w->last_accel[i] * G_TO_MS2;
    }
    wvqf_update(w->vqf, gyr, acc);
    wvqf_quat6d(w->vqf, w->q);
    wvqf_bias(w->vqf, w->bias);
    w->rest = wvqf_rest(w->vqf);
    if (w->first) {
        w->first = 0;
        memcpy(w->ref, w->q, sizeof(w->ref));
    }
}

void wabe_feed(wabe *w, const wabe_sample *accel, size_t na,
               const wabe_sample *gyro, size_t ng)
{
    pthread_mutex_lock(&w->lock);
    size_t ai = 0;
    for (size_t gi = 0; gi < ng; gi++) {
        while (ai < na && accel[ai].t <= gyro[gi].t) {
            accel_chip_to_base(accel[ai].v, w->last_accel);
            w->have_accel = 1;
            ai++;
        }
        if (w->have_accel)
            advance(w, gyro[gi].v);
    }
    while (ai < na) {
        accel_chip_to_base(accel[ai].v, w->last_accel);
        w->have_accel = 1;
        ai++;
    }
    if (ng > 0)
        w->last_t = gyro[ng - 1].t;
    else if (na > 0)
        w->last_t = accel[na - 1].t;
    pthread_mutex_unlock(&w->lock);
}

void wabe_set_lid(wabe *w, double deg)
{
    pthread_mutex_lock(&w->lock);
    wabe_lid_filter_push(&w->lid, deg, wabe_now());
    pthread_mutex_unlock(&w->lock);
}

void wabe_recenter(wabe *w)
{
    pthread_mutex_lock(&w->lock);
    memcpy(w->ref, w->q, sizeof(w->ref));
    pthread_mutex_unlock(&w->lock);
}

double wabe_relative_yaw(const double q[4], const double ref[4])
{
    double ref_inv[4], rel[4], m[3][3];
    quat_conj(ref, ref_inv);
    quat_mul(ref_inv, q, rel);
    quat_to_mat(rel, m);
    return atan2(m[1][0], m[0][0]) * RAD2DEG;
}

void wabe_read(wabe *w, wabe_orientation *out)
{
    pthread_mutex_lock(&w->lock);
    memset(out, 0, sizeof(*out));
    out->t = w->last_t;
    memcpy(out->q, w->q, sizeof(out->q));
    for (int i = 0; i < 3; i++)
        out->bias[i] = w->bias[i] * RAD2DEG;
    out->at_rest = w->rest;
    // Reconstructed to the moment it is being read, not held from the last hinge report. The
    // encoder updates at ~10 Hz and everything downstream publishes far faster; see lid_filter.c.
    const double lid = wabe_lid_filter_value(&w->lid, wabe_now());
    out->lid_deg = lid;

    // Laptop-intuitive angles. Roll/pitch absolute (gravity), yaw relative to the last
    // recenter. Signs: pitch + = front edge up, roll + = right side down, yaw + = CCW from
    // above.
    double m[3][3];
    quat_to_mat(w->q, m);
    const double about_x = atan2(m[2][1], m[2][2]); // about base X (left-right axis)
    const double about_y = -asin(fmax(-1.0, fmin(1.0, m[2][0]))); // about base Y (front-back)

    out->rpy[0] = about_y * RAD2DEG;
    out->rpy[1] = -about_x * RAD2DEG;
    out->rpy[2] = wabe_relative_yaw(w->q, w->ref);

    // Screen normal: base attitude ⊕ lid angle. Hinge axis = base +X; at lid angle L the
    // face normal in base frame is (0,0,1) rotated about X by (180-L) degrees.
    if (lid >= 0) {
        const double theta = (180.0 - lid) * DEG2RAD;
        const double nb[3] = {0, -sin(theta), cos(theta)};
        out->n[0] = m[0][0] * nb[0] + m[0][1] * nb[1] + m[0][2] * nb[2];
        out->n[1] = m[1][0] * nb[0] + m[1][1] * nb[1] + m[1][2] * nb[2];
        out->n[2] = m[2][0] * nb[0] + m[2][1] * nb[1] + m[2][2] * nb[2];
    }
    pthread_mutex_unlock(&w->lock);
}
