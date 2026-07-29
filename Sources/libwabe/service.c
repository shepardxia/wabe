// Daemon: publishes orientation as newline JSON on a unix socket. Protocol v0: every line the
// daemon sends is one orientation object; every line a client sends is a command (currently
// just "recenter"). Sensors and tracking belong to live.c.
#include "internal.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#define MAX_CLIENTS 64

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

int wabe_serve(const wabe_service *cfg)
{
    // SO_NOSIGPIPE on accepted fds is not enough: a client that connects, writes, and exits
    // before our accept() leaves a fd the setsockopt fails on, and the next broadcast send()
    // would kill the process with SIGPIPE (observed: `wabe recenter` == daemon exit 141).
    signal(SIGPIPE, SIG_IGN);

    const double publish_hz = cfg && cfg->publish_hz > 0 ? cfg->publish_hz : 30;
    const char *sock_path = cfg && cfg->socket_path ? cfg->socket_path : "/tmp/wabe.sock";

    int err = WABE_OK;
    wabe *w = wabe_start(cfg ? &cfg->sensors : NULL, &err);
    if (!w)
        return err;

    int server_fd = listen_unix(sock_path);
    if (server_fd < 0) {
        wabe_stop(w);
        return WABE_ERR_SOCKET;
    }
    fprintf(stderr, "wabed: %.1f Hz publish, socket %s\n", publish_hz, sock_path);

    // Each connection carries its own heading zero and its own rate. Sharing either would mean
    // one client's `recenter` snapping every other client's world, and one client's frame rate
    // dictating everyone's.
    struct client {
        int fd;
        double ref[4];
        double interval;
        double next_pub;
    } clients[MAX_CLIENTS];
    int nclients = 0;

    for (;;) {
        const double now = wabe_now();
        wabe_orientation o;
        wabe_read(w, &o);

        for (int i = 0; i < nclients;) {
            if (now < clients[i].next_pub) {
                i++;
                continue;
            }
            // Advance on a fixed grid. Resetting the deadline to `now` would fold each cycle's
            // overshoot into the next period, which cost ~4 Hz at a nominal 30 (measured).
            clients[i].next_pub += clients[i].interval;
            if (now - clients[i].next_pub > clients[i].interval)
                clients[i].next_pub = now + clients[i].interval;  // far behind: resync

            char line[512];
            int len = snprintf(line, sizeof(line),
                "{\"t\":%.4f,\"q\":[%.6f,%.6f,%.6f,%.6f],\"rpy\":[%.3f,%.3f,%.3f],"
                "\"lid\":%.2f,\"n\":[%.4f,%.4f,%.4f],\"bias\":[%.5f,%.5f,%.5f],\"stat\":%s}\n",
                now, o.q[0], o.q[1], o.q[2], o.q[3],
                o.rpy[0], o.rpy[1], wabe_relative_yaw(o.q, clients[i].ref), o.lid_deg,
                o.n[0], o.n[1], o.n[2], o.bias[0], o.bias[1], o.bias[2],
                o.at_rest ? "true" : "false");
            if (send(clients[i].fd, line, (size_t)len, 0) < 0 && errno != EAGAIN) {
                close(clients[i].fd);
                clients[i] = clients[--nclients];
            } else {
                i++;
            }
        }

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
            struct client *c = &clients[nclients++];
            c->fd = fd;
            memcpy(c->ref, o.q, sizeof(c->ref));  // heading zero starts where the client joined
            c->interval = 1.0 / publish_hz;
            c->next_pub = now;
        }

        char cmd[256];
        for (int i = 0; i < nclients; i++) {
            ssize_t n = read(clients[i].fd, cmd, sizeof(cmd) - 1);
            if (n <= 0)
                continue;
            cmd[n] = 0;
            if (strstr(cmd, "recenter"))
                memcpy(clients[i].ref, o.q, sizeof(clients[i].ref));
            const char *r = strstr(cmd, "rate ");
            if (r) {
                double hz = atof(r + 5);
                if (hz > 0)
                    clients[i].interval = 1.0 / (hz > 200 ? 200 : hz);
            }
        }
        usleep(2000);
    }
}
