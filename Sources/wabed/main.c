// wabed — the wabe daemon. Thin shell over libwabe: argument parsing and the accel-dead
// re-exec dance (the stall is sticky per process; a fresh process rolls fresh dice).
#include <wabe.h>

#include <mach-o/dyld.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    wabe_service cfg = {0};
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        const char *next = i + 1 < argc ? argv[i + 1] : NULL;
        if (!strcmp(a, "--rate") && next) {
            cfg.sensors.sensor_hz = atoi(argv[++i]);
        } else if (!strcmp(a, "--pub") && next) {
            cfg.publish_hz = atof(argv[++i]);
        } else if (!strcmp(a, "--sock") && next) {
            cfg.socket_path = argv[++i];
        } else if (!strcmp(a, "--record") && next) {
            cfg.sensors.record_path = argv[++i];
        } else if (!strcmp(a, "--help") || !strcmp(a, "-h")) {
            printf("wabed [--rate hz] [--pub hz] [--sock path] [--record raw.jsonl]\n");
            return 0;
        } else {
            fprintf(stderr, "unknown arg: %s\n", a);
            return 2;
        }
    }

    int err = wabe_serve(&cfg);
    if (err == WABE_ERR_ACCEL_DEAD) {
        const char *env = getenv("WABE_RESPAWN");
        int respawns = env ? atoi(env) : 0;
        if (respawns >= 5) {
            fprintf(stderr, "wabed: accel dead after %d respawns, giving up\n", respawns);
            return 1;
        }
        fprintf(stderr, "wabed: accel dead, re-exec (%d/5)\n", respawns + 1);
        char buf[16];
        snprintf(buf, sizeof(buf), "%d", respawns + 1);
        setenv("WABE_RESPAWN", buf, 1);
        char exe[4096];
        uint32_t size = sizeof(exe);
        if (_NSGetExecutablePath(exe, &size) == 0)
            execv(exe, argv);
        fprintf(stderr, "wabed: execv failed\n");
        return 1;
    }
    if (err != WABE_OK) {
        static const char *msgs[] = {
            [WABE_ERR_WAKE] = "SPU wake failed — no AppleSPUHIDDriver services accepted properties",
            [WABE_ERR_OPEN] = "sensor reader failed to start (accel/gyro not openable)",
            [WABE_ERR_SOCKET] = "bind/listen failed on socket",
            [WABE_ERR_RECORD] = "cannot open record file",
        };
        fprintf(stderr, "wabed: %s\n", msgs[err] ? msgs[err] : "unknown error");
        return 1;
    }
    return 0;
}
