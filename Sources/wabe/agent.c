// Installing this binary as a per-user launchd agent. No root anywhere: the plist goes in the
// user's own LaunchAgents and is bootstrapped into their gui domain.
#include "cli.h"

#include <copyfile.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

static const char *home(void)
{
    const char *h = getenv("HOME");
    return h && *h ? h : ".";
}

static void path_in_home(char *out, size_t n, const char *rest)
{
    snprintf(out, n, "%s/%s", home(), rest);
}

/// Exit status of a command, or -1 if it could not be started. Unless `quiet`, output is inherited
/// so launchctl's own diagnostics reach the user unedited.
static int run(const char *path, char *const argv[], int quiet)
{
    posix_spawn_file_actions_t acts;
    posix_spawn_file_actions_init(&acts);
    int devnull = -1;
    if (quiet && (devnull = open("/dev/null", O_WRONLY)) >= 0) {
        posix_spawn_file_actions_adddup2(&acts, devnull, 1);
        posix_spawn_file_actions_adddup2(&acts, devnull, 2);
    }
    pid_t pid;
    const int spawned = posix_spawn(&pid, path, &acts, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&acts);
    if (devnull >= 0)
        close(devnull);
    if (spawned != 0)
        return -1;
    int status = 0;
    if (waitpid(pid, &status, 0) < 0)
        return -1;
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

static void service_target(char *out, size_t n)
{
    snprintf(out, n, "gui/%u/%s", getuid(), WABE_LABEL);
}

int wabe_agent_loaded(void)
{
    char target[128];
    service_target(target, sizeof(target));
    char *argv[] = {"launchctl", "print", target, NULL};
    return run("/bin/launchctl", argv, 1) == 0;  // quiet: print dumps the whole job on success
}

static int mkdir_p(const char *path)
{
    char buf[PATH_MAX];
    snprintf(buf, sizeof(buf), "%s", path);
    for (char *p = buf + 1; *p; p++) {
        if (*p != '/')
            continue;
        *p = 0;
        mkdir(buf, 0755);
        *p = '/';
    }
    return mkdir(buf, 0755) == 0 || errno == EEXIST ? 0 : -1;
}

int wabe_cmd_install(const char *sock_path)
{
    char bin_dir[PATH_MAX], installed[PATH_MAX], plist[PATH_MAX], log[PATH_MAX], agents[PATH_MAX];
    path_in_home(bin_dir, sizeof(bin_dir), ".local/bin");
    path_in_home(agents, sizeof(agents), "Library/LaunchAgents");
    snprintf(installed, sizeof(installed), "%s/wabe", bin_dir);
    snprintf(plist, sizeof(plist), "%s/%s.plist", agents, WABE_LABEL);
    path_in_home(log, sizeof(log), "Library/Logs/wabe.log");

    if (mkdir_p(bin_dir) != 0 || mkdir_p(agents) != 0) {
        fprintf(stderr, "wabe: cannot create %s: %s\n", bin_dir, strerror(errno));
        return 1;
    }

    // COPYFILE_ALL keeps the modification time, which is the whole basis of the staleness check in
    // `wabe status`: the installed daemon and the build it came from have to look identical.
    const char *self = wabe_self_path();
    if (strcmp(self, installed) != 0
        && copyfile(self, installed, NULL, COPYFILE_ALL | COPYFILE_UNLINK) != 0) {
        fprintf(stderr, "wabe: cannot install to %s: %s\n", installed, strerror(errno));
        return 1;
    }

    FILE *f = fopen(plist, "w");
    if (!f) {
        fprintf(stderr, "wabe: cannot write %s: %s\n", plist, strerror(errno));
        return 1;
    }
    // ProcessType is deliberately absent: setting it to Background throttles the publish loop from
    // 30 Hz to about 17. Measured; see NOTES.md.
    fprintf(f,
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
            "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" "
            "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
            "<plist version=\"1.0\">\n<dict>\n"
            "    <key>Label</key><string>%s</string>\n"
            "    <key>ProgramArguments</key>\n    <array>\n"
            "        <string>%s</string>\n"
            "        <string>serve</string>\n"
            "        <string>--sock</string><string>%s</string>\n"
            "    </array>\n"
            "    <key>RunAtLoad</key><true/>\n"
            "    <key>KeepAlive</key><true/>\n"
            "    <key>StandardErrorPath</key><string>%s</string>\n"
            "    <key>StandardOutPath</key><string>%s</string>\n"
            "</dict>\n</plist>\n",
            WABE_LABEL, installed, sock_path, log, log);
    fclose(f);

    char target[128];
    service_target(target, sizeof(target));
    char domain[64];
    snprintf(domain, sizeof(domain), "gui/%u", getuid());

    char *bootout[] = {"launchctl", "bootout", target, NULL};
    run("/bin/launchctl", bootout, 1);  // may not be loaded, and that is not an error here
    // bootout returns before the job is actually gone, and bootstrapping over one still on its way
    // out fails with EIO. Wait for the domain to forget it.
    for (int i = 0; i < 50 && wabe_agent_loaded(); i++)
        usleep(100000);

    char *bootstrap[] = {"launchctl", "bootstrap", domain, plist, NULL};
    if (run("/bin/launchctl", bootstrap, 0) != 0) {
        fprintf(stderr, "wabe: launchctl bootstrap failed\n");
        return 1;
    }

    for (int i = 0; i < 50; i++) {
        int fd = wabe_connect(sock_path);
        if (fd >= 0) {
            close(fd);
            printf("wabe installed and running\n");
            printf("  daemon  %s\n", installed);
            printf("  agent   %s  (starts at login)\n", plist);
            printf("  socket  %s\n", sock_path);
            printf("  log     %s\n", log);
            const char *path = getenv("PATH");
            if (!path || !strstr(path, bin_dir)) {
                printf("\nadd %s to your PATH to run `wabe` from anywhere:\n", bin_dir);
                printf("  fish_add_path %s\n", bin_dir);
                printf("  export PATH=\"%s:$PATH\"\n", bin_dir);
            }
            return 0;
        }
        usleep(100000);
    }
    fprintf(stderr, "wabe: agent loaded but no socket after 5 s — see %s\n", log);
    return 1;
}

int wabe_cmd_uninstall(void)
{
    char target[128], plist[PATH_MAX], installed[PATH_MAX];
    service_target(target, sizeof(target));
    path_in_home(plist, sizeof(plist), "Library/LaunchAgents/" WABE_LABEL ".plist");
    path_in_home(installed, sizeof(installed), ".local/bin/wabe");

    char *bootout[] = {"launchctl", "bootout", target, NULL};
    run("/bin/launchctl", bootout, 1);
    unlink(plist);
    unlink(installed);
    printf("wabe uninstalled: agent stopped, %s removed\n", installed);
    return 0;
}
