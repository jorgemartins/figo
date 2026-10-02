#ifndef FIGO_PTY_H
#define FIGO_PTY_H

#include <stdbool.h>
#include <stdint.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <termios.h>

/// Forks a child attached to a new pseudo-terminal and replaces it with `path`.
///
/// `argv` and `envp` are NULL-terminated. `term` and `ws` seed the new terminal's line
/// discipline and size and may be NULL. On success returns the child's pid in the parent and
/// stores the pty master in `*master`; returns -1 if the fork failed. If the exec fails the
/// child exits with status 127.
pid_t figo_pty_spawn(int *master, const char *path, char *const argv[], char *const envp[],
                     const struct termios *term, const struct winsize *ws);

/// Waits until one of the descriptors is ready, a signal arrives, or the timeout expires
/// (`timeout_ms` < 0 waits forever).
///
/// select() is used because poll() and kqueue() are unreliable for terminal devices on macOS.
/// On return bit i of `*read_ready` / `*write_ready` is set when `read_fds[i]` / `write_fds[i]`
/// is ready; at most 32 descriptors each. Returns select()'s result (-1 with errno on error).
int figo_wait(const int *read_fds, int read_count, const int *write_fds, int write_count,
              int timeout_ms, uint32_t *read_ready, uint32_t *write_ready);

/// Routes SIGWINCH and SIGCHLD into a pipe so they can be waited for alongside descriptors.
/// Each delivery writes one byte holding the signal number. Returns the read end, or -1.
int figo_signal_pipe(void);

/// Arms the last line of defence for the user's shell.
///
/// The wrapper sits between the terminal and the shell, so if it crashed the shell would die
/// with it and the terminal tab would close. Once armed, a fatal signal (SIGSEGV, SIGBUS,
/// SIGILL, SIGTRAP, SIGABRT, SIGFPE) no longer kills the process: the handler takes over and
/// copies bytes between the terminal and the pty until the shell exits, then restores `original`
/// on the terminal and exits with the shell's status. Autocomplete is gone for that tab, but
/// the shell and everything running in it survive.
void figo_lifeboat_arm(int master, pid_t child, const struct termios *original);

/// True once a fatal signal has been caught and the lifeboat loop is running.
bool figo_lifeboat_active(void);

#endif
