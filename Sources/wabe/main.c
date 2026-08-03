// wabe — one binary. `wabe serve` is the daemon; everything else talks to one, or installs it.
// Keeping the daemon and its control surface in the same executable is what lets `wabe status`
// answer "is the thing running the thing I just built", which nothing else here can answer.
#include "cli.h"
#include <wabe.h>

#include <mach-o/dyld.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const char USAGE[] =
    "wabe — MacBook orientation service\n"
    "\n"
    "  wabe status              agent, publish rate, current orientation  (default)\n"
    "  wabe watch [--raw]       live readout\n"
    "  wabe recenter            zero the relative heading\n"
    "  wabe install             run at login, per user, no root\n"
    "  wabe uninstall           stop and remove\n"
    "  wabe serve [options]     run the daemon here instead of as an agent\n"
    "\n"
    "options: --sock <path>          socket to use          (default /tmp/wabe.sock)\n"
    "  serve: --rate <hz>            IMU sample rate        (default 795)\n"
    "         --pub <hz>             publish rate           (default 30)\n"
    "         --record <raw.jsonl>   also write a raw capture\n";

/// Re-exec on a dead sensor stream. The stall is decided when the stream opens and is sticky for
/// the life of the process, so nothing in-process revives it; a fresh process rolls again.
static int respawn(char **argv, int err)
{
    const char *env = getenv("WABE_RESPAWN");
    const int tries = env ? atoi(env) : 0;
    if (tries >= 5) {
        fprintf(stderr, "wabe: IMU stream still dead after %d respawns, giving up. This is a\n"
                        "      driver stall, not a config error; try again, and see NOTES.md.\n",
                tries);
        return 1;
    }
    fprintf(stderr, "wabe: %s stream dead, re-exec (%d/5)\n",
            err == WABE_ERR_ACCEL_DEAD ? "accelerometer" : "gyroscope", tries + 1);
    char buf[16];
    snprintf(buf, sizeof(buf), "%d", tries + 1);
    setenv("WABE_RESPAWN", buf, 1);
    char exe[4096];
    uint32_t size = sizeof(exe);
    if (_NSGetExecutablePath(exe, &size) == 0)
        execv(exe, argv);
    fprintf(stderr, "wabe: execv failed\n");
    return 1;
}

static int serve(wabe_service *cfg, char **argv)
{
    const int err = wabe_serve(cfg);
    if (err == WABE_ERR_ACCEL_DEAD || err == WABE_ERR_GYRO_DEAD)
        return respawn(argv, err);
    if (err != WABE_OK) {
        static const char *msgs[] = {
            [WABE_ERR_WAKE] = "no AppleSPUHIDDriver service accepted the wake properties. This Mac\n"
                              "      most likely has no SPU IMU: it arrived with M2 and is absent on\n"
                              "      Intel, M1 and desktop Macs. See NOTES.md for model coverage.",
            [WABE_ERR_OPEN] = "the sensors are present but would not open",
            [WABE_ERR_LAYOUT] = "the IMU sends reports, but none of its byte offsets hold gravity,\n"
                                "      so this Mac lays them out in a way wabe has not seen. Refusing\n"
                                "      to publish guessed values. Please open an issue with the model.",
            [WABE_ERR_SOCKET] = "could not bind the socket (detail above)",
            [WABE_ERR_RECORD] = "could not open the capture file (detail above)",
        };
        fprintf(stderr, "wabe: %s\n", msgs[err] ? msgs[err] : "unknown error");
        return 1;
    }
    return 0;
}

int main(int argc, char **argv)
{
    wabe_service cfg = {0};
    const char *sock = "/tmp/wabe.sock";
    const char *command = "status";
    int raw = 0;

    int i = 1;
    if (i < argc && argv[i][0] != '-') {
        command = argv[i++];
        if (strcmp(command, "status") && strcmp(command, "watch") && strcmp(command, "recenter")
            && strcmp(command, "install") && strcmp(command, "uninstall")
            && strcmp(command, "serve")) {
            fprintf(stderr, "wabe: unknown command %s\n\n%s", command, USAGE);
            return 2;
        }
    }
    for (; i < argc; i++) {
        const char *a = argv[i];
        const char *next = i + 1 < argc ? argv[i + 1] : NULL;
        if (!strcmp(a, "--sock") && next)
            sock = argv[++i];
        else if (!strcmp(a, "--rate") && next)
            cfg.sensors.sensor_hz = atoi(argv[++i]);
        else if (!strcmp(a, "--pub") && next)
            cfg.publish_hz = atof(argv[++i]);
        else if (!strcmp(a, "--record") && next)
            cfg.sensors.record_path = argv[++i];
        else if (!strcmp(a, "--raw"))
            raw = 1;
        else if (!strcmp(a, "--help") || !strcmp(a, "-h")) {
            printf("%s", USAGE);
            return 0;
        } else {
            fprintf(stderr, "wabe: unknown argument %s\n\n%s", a, USAGE);
            return 2;
        }
    }
    cfg.socket_path = sock;

    if (!strcmp(command, "serve"))
        return serve(&cfg, argv);
    if (!strcmp(command, "install"))
        return wabe_cmd_install(sock);
    if (!strcmp(command, "uninstall"))
        return wabe_cmd_uninstall();
    if (!strcmp(command, "watch"))
        return wabe_cmd_watch(sock, raw);
    if (!strcmp(command, "recenter"))
        return wabe_cmd_recenter(sock);
    return wabe_cmd_status(sock);
}
