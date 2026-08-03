// The three things `wabe` can do besides serve: talk to a daemon already running, install itself
// as a launchd agent, and remove itself again. Split out so main.c stays argument parsing.
#ifndef WABE_CLI_H
#define WABE_CLI_H

#include <stddef.h>

#define WABE_LABEL "dev.wabe.wabed"

/// Connected socket to the daemon, or -1. Prints nothing.
int wabe_connect(const char *sock_path);

/// Same, but explains where a daemon comes from and exits when there is none.
int wabe_require(const char *sock_path);

int wabe_cmd_status(const char *sock_path);
int wabe_cmd_watch(const char *sock_path, int raw);
int wabe_cmd_recenter(const char *sock_path);

int wabe_cmd_install(const char *sock_path);
int wabe_cmd_uninstall(void);

/// Whether launchd currently has the agent loaded.
int wabe_agent_loaded(void);

/// Absolute path of the running executable. Static buffer, never NULL.
const char *wabe_self_path(void);

/// Whether the daemon on the other end of `fd` is running this same binary, compared by inode and
/// then by size and modification time. `what` receives its executable path.
int wabe_daemon_is_self(int fd, char *what, size_t n);

#endif
