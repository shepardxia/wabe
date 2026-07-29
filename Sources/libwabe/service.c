// Daemon service: owns the sensor core, runs the filter, publishes newline-JSON poses on a
// unix socket. Protocol v0: every line the daemon sends is one pose object; every line a
// client sends is a command (currently just "recenter").
#include "include/wabe.h"
#include "wabe_sensor.h"

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#define MAX_CLIENTS 64
#define DRAIN_CAP 2048

static double epoch_now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static volatile double g_lid_deg = -1;

static void *lid_thread(void *arg)
{
    (void)arg;
    for (;;) {
        double d = ws_lid_deg();
        if (d >= 0)
            g_lid_deg = d;
        usleep(100000);
    }
    return NULL;
}

// ws_sample (float triple) -> wabe_sample (double vector), the filter/record input form.
static void widen(const ws_sample *in, wabe_sample *out, size_t n)
{
    for (size_t i = 0; i < n; i++) {
        out[i].t = in[i].t;
        out[i].v[0] = in[i].x;
        out[i].v[1] = in[i].y;
        out[i].v[2] = in[i].z;
    }
}

static void record_samples(FILE *f, char tag, const wabe_sample *s, size_t n)
{
    for (size_t i = 0; i < n; i++)
        fprintf(f, "{\"s\":\"%c\",\"t\":%.6f,\"v\":[%.9g,%.9g,%.9g]}\n",
                tag, s[i].t, s[i].v[0], s[i].v[1], s[i].v[2]);
}

static int listen_unix(const char *path)
{
    unlink(path);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0)
        return -1;
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(fd, 8) != 0) {
        close(fd);
        return -1;
    }
    chmod(path, 0666);
    fcntl(fd, F_SETFL, O_NONBLOCK);
    return fd;
}

int wabe_service_run(const wabe_config *cfg)
{
    // SO_NOSIGPIPE on accepted fds is not enough: a client that connects, writes, and exits
    // before our accept() leaves a fd the setsockopt fails on, and the next broadcast send()
    // would kill the process with SIGPIPE (observed: `wabe-cli recenter` == daemon exit 141).
    signal(SIGPIPE, SIG_IGN);

    const int sensor_hz = cfg && cfg->sensor_hz > 0 ? cfg->sensor_hz : 795;
    const double publish_hz = cfg && cfg->publish_hz > 0 ? cfg->publish_hz : 30;
    const char *sock_path = cfg && cfg->socket_path ? cfg->socket_path : "/tmp/wabe.sock";
    const char *record_path = cfg ? cfg->record_path : NULL;

    int interval = 1000000 / sensor_hz;
    if (interval < 1)
        interval = 1;
    // WABE_NO_WAKE: skip the driver property writes (sensors must already be awake).
    if (!getenv("WABE_NO_WAKE") && ws_wake(interval) <= 0)
        return WABE_ERR_WAKE;
    if (ws_start() != 0)
        return WABE_ERR_OPEN;
    // The accel stream is stochastically dead per process instance and nothing in-process
    // revives it (see NOTES.md). Callers re-exec on this error for a fresh roll.
    if (!(ws_opened_mask() & 1)) {
        ws_stop();
        return WABE_ERR_ACCEL_DEAD;
    }

    FILE *recorder = NULL;
    if (record_path) {
        recorder = fopen(record_path, "w");
        if (!recorder)
            return WABE_ERR_RECORD;
        setvbuf(recorder, NULL, _IOFBF, 1 << 16);
        fprintf(recorder, "{\"s\":\"meta\",\"rate\":%d,\"start\":%.6f}\n", sensor_hz, epoch_now());
    }

    int server_fd = listen_unix(sock_path);
    if (server_fd < 0)
        return WABE_ERR_SOCKET;
    fprintf(stderr, "wabed: %d Hz sensors, %.1f Hz publish, vqf filter, socket %s\n",
            sensor_hz, publish_hz, sock_path);

    pthread_t lid;
    pthread_create(&lid, NULL, lid_thread, NULL);

    wabe_filter *filter = wabe_filter_new(sensor_hz);
    static ws_sample accel_raw[DRAIN_CAP], gyro_raw[DRAIN_CAP];
    static wabe_sample accel[DRAIN_CAP], gyro[DRAIN_CAP];
    int clients[MAX_CLIENTS];
    int nclients = 0;
    double last_pub = 0;
    const double pub_interval = 1.0 / publish_hz;
    const int debug = getenv("WABE_DEBUG") != NULL;
    long dbg_a = 0, dbg_g = 0;
    double dbg_last = epoch_now();

    for (;;) {
        const size_t na = ws_read_accel(accel_raw, DRAIN_CAP);
        const size_t ng = ws_read_gyro(gyro_raw, DRAIN_CAP);
        widen(accel_raw, accel, na);
        widen(gyro_raw, gyro, ng);
        wabe_filter_feed(filter, accel, na, gyro, ng);

        if (debug) {
            dbg_a += (long)na;
            dbg_g += (long)ng;
            double now = epoch_now();
            if (now - dbg_last >= 1) {
                fprintf(stderr, "debug: accel %ld/s gyro %ld/s, clients=%d, lid=%.2f\n",
                        dbg_a, dbg_g, nclients, g_lid_deg);
                dbg_a = dbg_g = 0;
                dbg_last = now;
            }
        }

        if (recorder) {
            record_samples(recorder, 'a', accel, na);
            record_samples(recorder, 'g', gyro, ng);
        }

        const double now = epoch_now();
        if (ng > 0 && now - last_pub >= pub_interval) {
            // Advance on a fixed grid. Resetting the deadline to `now` would fold each cycle's
            // overshoot into the next period, which cost ~4 Hz at a nominal 30 (measured).
            last_pub += pub_interval;
            if (now - last_pub > pub_interval)
                last_pub = now;  // fell far behind (startup, stall): resync rather than burst
            wabe_filter_set_lid(filter, g_lid_deg);
            if (recorder && g_lid_deg >= 0) {
                fprintf(recorder, "{\"s\":\"l\",\"t\":%.6f,\"d\":%.2f}\n", now, g_lid_deg);
                fflush(recorder);
            }
            wabe_pose p;
            wabe_filter_pose(filter, now, &p);
            char line[512];
            int len = snprintf(line, sizeof(line),
                "{\"t\":%.4f,\"q\":[%.6f,%.6f,%.6f,%.6f],\"rpy\":[%.3f,%.3f,%.3f],"
                "\"lid\":%.2f,\"n\":[%.4f,%.4f,%.4f],\"bias\":[%.5f,%.5f,%.5f],\"stat\":%s}\n",
                p.t, p.q[0], p.q[1], p.q[2], p.q[3],
                p.rpy[0], p.rpy[1], p.rpy[2], p.lid_deg,
                p.n[0], p.n[1], p.n[2], p.bias[0], p.bias[1], p.bias[2],
                p.stationary ? "true" : "false");
            for (int i = 0; i < nclients;) {
                if (send(clients[i], line, (size_t)len, 0) < 0 && errno != EAGAIN) {
                    close(clients[i]);
                    clients[i] = clients[--nclients];
                } else {
                    i++;
                }
            }
        }

        // Accept new clients, poll existing ones for commands.
        for (;;) {
            int fd = accept(server_fd, NULL, NULL);
            if (fd < 0)
                break;
            if (nclients >= MAX_CLIENTS) {
                close(fd);
                continue;
            }
            fcntl(fd, F_SETFL, O_NONBLOCK);
            int one = 1;
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
            clients[nclients++] = fd;
        }
        char cmd[256];
        for (int i = 0; i < nclients; i++) {
            ssize_t n = read(clients[i], cmd, sizeof(cmd) - 1);
            if (n > 0) {
                cmd[n] = 0;
                if (strstr(cmd, "recenter"))
                    wabe_filter_recenter(filter);
            }
        }
        usleep(2000);
    }
}
