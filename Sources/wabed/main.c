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
    // Both stream stalls are per-process dice; a fresh process rerolls them.
    if (err == WABE_ERR_ACCEL_DEAD || err == WABE_ERR_GYRO_DEAD) {
        const char *env = getenv("WABE_RESPAWN");
        int respawns = env ? atoi(env) : 0;
        if (respawns >= 5) {
            fprintf(stderr, "wabed: IMU stream still dead after %d respawns, giving up. This is a\n"
                            "       driver stall, not a config error; try again, and see NOTES.md.\n",
                    respawns);
            return 1;
        }
        fprintf(stderr, "wabed: %s stream dead, re-exec (%d/5)\n",
                err == WABE_ERR_ACCEL_DEAD ? "accelerometer" : "gyroscope", respawns + 1);
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
            [WABE_ERR_WAKE] = "no AppleSPUHIDDriver service accepted the wake properties. This Mac\n"
                              "       most likely has no SPU IMU: it arrived with M2 and is absent on\n"
                              "       Intel, M1 and desktop Macs. See NOTES.md for model coverage.",
            [WABE_ERR_OPEN] = "the sensors are present but would not open",
            [WABE_ERR_LAYOUT] = "the IMU sends reports, but none of its byte offsets hold gravity,\n"
                                "       so this Mac lays them out in a way wabe has not seen. Refusing\n"
                                "       to publish guessed values. Please open an issue with the model.",
            [WABE_ERR_SOCKET] = "could not bind the socket (detail above)",
            [WABE_ERR_RECORD] = "could not open the capture file (detail above)",
        };
        fprintf(stderr, "wabed: %s\n", msgs[err] ? msgs[err] : "unknown error");
        return 1;
    }
    return 0;
}
