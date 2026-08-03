// Talking to a daemon that is already running: the socket, the published line, and the question
// of whether that daemon is the binary you just built.
#include "cli.h"

#include <errno.h>
#include <libproc.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>

const char *wabe_self_path(void)
{
    static char resolved[PATH_MAX];
    if (resolved[0])
        return resolved;
    char raw[PATH_MAX];
    uint32_t size = sizeof(raw);
    if (_NSGetExecutablePath(raw, &size) != 0 || !realpath(raw, resolved))
        snprintf(resolved, sizeof(resolved), "wabe");
    return resolved;
}

int wabe_connect(const char *sock_path)
{
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0)
        return -1;
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, sock_path, sizeof(addr.sun_path) - 1);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

int wabe_require(const char *sock_path)
{
    int fd = wabe_connect(sock_path);
    if (fd < 0) {
        fprintf(stderr, "no daemon on %s — `wabe install`, or `wabe serve` to run one here\n",
                sock_path);
        exit(1);
    }
    return fd;
}

// ------------------------------------------------------------------ the published line

/// Reads one newline-terminated line into `buf`. Returns its length, or -1 at EOF. The daemon
/// writes whole lines, so the only splitting that matters is across read() boundaries.
static int read_line(int fd, char *buf, size_t n)
{
    static char pending[8192];
    static size_t held;
    for (;;) {
        char *nl = memchr(pending, '\n', held);
        if (nl) {
            size_t len = (size_t)(nl - pending);
            size_t copy = len < n - 1 ? len : n - 1;
            memcpy(buf, pending, copy);
            buf[copy] = 0;
            held -= len + 1;
            memmove(pending, nl + 1, held);
            return (int)copy;
        }
        if (held == sizeof(pending))
            held = 0;  // a line that long is not ours; drop it rather than wedge
        ssize_t got = read(fd, pending + held, sizeof(pending) - held);
        if (got <= 0)
            return -1;
        held += (size_t)got;
    }
}

/// Numbers under `key` in a flat JSON object: `"key":1.5` or `"key":[1,2,3]`. Returns how many
/// were read. Hand-written against service.c's writer, which is the only thing that produces
/// these lines; a renamed field shows up as a field that reads zero.
static int json_nums(const char *line, const char *key, double *out, int want)
{
    char pat[32];
    snprintf(pat, sizeof(pat), "\"%s\":", key);
    const char *p = strstr(line, pat);
    if (!p)
        return 0;
    p += strlen(pat);
    if (*p == '[')
        p++;
    int got = 0;
    while (got < want) {
        char *end;
        double v = strtod(p, &end);
        if (end == p)
            break;
        out[got++] = v;
        p = end;
        if (*p == ',')
            p++;
        else
            break;
    }
    return got;
}

static int json_true(const char *line, const char *key)
{
    char pat[32];
    snprintf(pat, sizeof(pat), "\"%s\":", key);
    const char *p = strstr(line, pat);
    return p && !strncmp(p + strlen(pat), "true", 4);
}

/// A published orientation, as much of it as the readouts use.
typedef struct {
    double t, rpy[3], lid, n[3];
    int at_rest;
} pose;

static int parse_pose(const char *line, pose *o)
{
    if (json_nums(line, "t", &o->t, 1) != 1)
        return 0;
    if (json_nums(line, "rpy", o->rpy, 3) != 3)
        return 0;
    if (json_nums(line, "lid", &o->lid, 1) != 1)
        return 0;
    json_nums(line, "n", o->n, 3);
    o->at_rest = json_true(line, "stat");
    return 1;
}

static void print_angles(const pose *o, int with_normal)
{
    printf("roll %+7.2f°  pitch %+7.2f°  yaw %+7.2f°", o->rpy[0], o->rpy[1], o->rpy[2]);
    if (o->lid < 0)
        printf("  (no hinge encoder)");
    else
        printf("  lid %6.2f°", o->lid);
    if (with_normal && o->lid >= 0)
        printf("  n [%+.3f %+.3f %+.3f]", o->n[0], o->n[1], o->n[2]);
}

// ------------------------------------------------------------------ is it this build?

int wabe_daemon_is_self(int fd, char *what, size_t n)
{
    send(fd, "info\n", 5, 0);
    // The daemon keeps publishing while it answers, so skip past pose lines to the reply.
    char line[1024];
    int pid = -1;
    for (int i = 0; i < 200; i++) {
        if (read_line(fd, line, sizeof(line)) < 0)
            break;
        double v;
        if (strstr(line, "\"info\"") && json_nums(line, "pid", &v, 1) == 1) {
            pid = (int)v;
            break;
        }
    }
    char theirs[PROC_PIDPATHINFO_MAXSIZE] = {0};
    struct stat a, b;
    if (pid < 0 || proc_pidpath(pid, theirs, sizeof(theirs)) <= 0
        || stat(theirs, &a) != 0 || stat(wabe_self_path(), &b) != 0) {
        snprintf(what, n, "unreadable");
        return 0;
    }
    snprintf(what, n, "%s", theirs);
    if (a.st_dev == b.st_dev && a.st_ino == b.st_ino)
        return 1;
    // Install copies with metadata intact, so the installed daemon and the build it came from are
    // the same size and carry the same mtime. Anything else is a daemon from a different build.
    return a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_size == b.st_size;
}

// ------------------------------------------------------------------ commands

int wabe_cmd_recenter(const char *sock_path)
{
    int fd = wabe_require(sock_path);
    if (send(fd, "recenter\n", 9, 0) < 0) {
        fprintf(stderr, "wabe: could not send recenter: %s\n", strerror(errno));
        return 1;
    }
    close(fd);
    printf("recentered\n");
    return 0;
}

int wabe_cmd_watch(const char *sock_path, int raw)
{
    int fd = wabe_require(sock_path);
    char line[1024];
    while (read_line(fd, line, sizeof(line)) >= 0) {
        if (raw) {
            printf("%s\n", line);
            continue;
        }
        pose o;
        if (!parse_pose(line, &o))
            continue;
        printf("\033[2K\r");
        print_angles(&o, 1);
        printf(o.at_rest ? " ·" : " ≈");
        fflush(stdout);
    }
    printf("\n");
    close(fd);
    return 0;
}

int wabe_cmd_status(const char *sock_path)
{
    const int loaded = wabe_agent_loaded();
    printf("agent    %s  (%s)\n", loaded ? "loaded" : "not installed", WABE_LABEL);

    int fd = wabe_connect(sock_path);
    if (fd < 0) {
        printf("socket   %s: not responding\n", sock_path);
        if (loaded)
            printf("\nthe agent is loaded but nothing answers, so the daemon is failing to start.\n"
                   "see ~/Library/Logs/wabe.log\n");
        else
            printf("\nstart it with `wabe install`, or `wabe serve` to run one in the foreground\n");
        return 1;
    }

    char which[PATH_MAX] = {0};
    const int same = wabe_daemon_is_self(fd, which, sizeof(which));

    pose o, first;
    int count = 0;
    char line[1024];
    while (count < 30 && read_line(fd, line, sizeof(line)) >= 0) {
        if (!parse_pose(line, &o))
            continue;
        if (count == 0)
            first = o;
        count++;
    }
    close(fd);
    if (count < 2) {
        printf("socket   %s: connected but no poses\n", sock_path);
        return 1;
    }
    const double span = o.t - first.t;
    printf("socket   %s: %.0f Hz\n", sock_path, span > 1e-6 ? (count - 1) / span : 0.0);
    printf("daemon   %s%s\n", which, same ? "" : "   ← not this build, `wabe install` to replace it");
    if (o.lid < 0)
        printf("hinge    absent on this machine: no screen normal\n");
    printf("pose     ");
    print_angles(&o, 0);
    printf(o.at_rest ? "  at rest\n" : "  moving\n");
    return 0;
}
