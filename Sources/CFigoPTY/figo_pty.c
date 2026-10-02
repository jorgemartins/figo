#include "figo_pty.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/wait.h>
#include <unistd.h>
#include <util.h>

pid_t figo_pty_spawn(int *master, const char *path, char *const argv[], char *const envp[],
                     const struct termios *term, const struct winsize *ws) {
  pid_t pid = forkpty(master, NULL, (struct termios *)term, (struct winsize *)ws);
  if (pid != 0) {
    return pid;
  }

  // Child: only async-signal-safe calls from here to exec.
  sigset_t empty;
  sigemptyset(&empty);
  sigprocmask(SIG_SETMASK, &empty, NULL);
  for (int sig = 1; sig < NSIG; sig++) {
    signal(sig, SIG_DFL);
  }
  // The shell must not inherit the wrapper's sockets and pipes.
  for (int fd = 3; fd < 256; fd++) {
    close(fd);
  }

  execve(path, argv, envp);
  _exit(127);
}

int figo_wait(const int *read_fds, int read_count, const int *write_fds, int write_count,
              int timeout_ms, uint32_t *read_ready, uint32_t *write_ready) {
  fd_set readable, writable;
  FD_ZERO(&readable);
  FD_ZERO(&writable);
  int highest = -1;
  for (int i = 0; i < read_count && i < 32; i++) {
    if (read_fds[i] < 0 || read_fds[i] >= FD_SETSIZE) continue;
    FD_SET(read_fds[i], &readable);
    if (read_fds[i] > highest) highest = read_fds[i];
  }
  for (int i = 0; i < write_count && i < 32; i++) {
    if (write_fds[i] < 0 || write_fds[i] >= FD_SETSIZE) continue;
    FD_SET(write_fds[i], &writable);
    if (write_fds[i] > highest) highest = write_fds[i];
  }

  struct timeval timeout;
  struct timeval *timeout_ptr = NULL;
  if (timeout_ms >= 0) {
    timeout.tv_sec = timeout_ms / 1000;
    timeout.tv_usec = (timeout_ms % 1000) * 1000;
    timeout_ptr = &timeout;
  }

  *read_ready = 0;
  *write_ready = 0;
  int result = select(highest + 1, &readable, &writable, NULL, timeout_ptr);
  if (result <= 0) {
    return result;
  }
  for (int i = 0; i < read_count && i < 32; i++) {
    if (read_fds[i] >= 0 && read_fds[i] < FD_SETSIZE && FD_ISSET(read_fds[i], &readable)) {
      *read_ready |= (uint32_t)1 << i;
    }
  }
  for (int i = 0; i < write_count && i < 32; i++) {
    if (write_fds[i] >= 0 && write_fds[i] < FD_SETSIZE && FD_ISSET(write_fds[i], &writable)) {
      *write_ready |= (uint32_t)1 << i;
    }
  }
  return result;
}

// MARK: - Signal pipe

static int signal_pipe_write = -1;

static void forward_signal(int sig) {
  int saved = errno;
  unsigned char byte = (unsigned char)sig;
  // A full pipe means a wake-up is already pending, which is all that is needed.
  (void)write(signal_pipe_write, &byte, 1);
  errno = saved;
}

int figo_signal_pipe(void) {
  int fds[2];
  if (pipe(fds) != 0) {
    return -1;
  }
  for (int i = 0; i < 2; i++) {
    fcntl(fds[i], F_SETFL, fcntl(fds[i], F_GETFL) | O_NONBLOCK);
    fcntl(fds[i], F_SETFD, FD_CLOEXEC);
  }
  signal_pipe_write = fds[1];

  struct sigaction action;
  memset(&action, 0, sizeof(action));
  action.sa_handler = forward_signal;
  action.sa_flags = SA_RESTART;
  sigemptyset(&action.sa_mask);
  sigaction(SIGWINCH, &action, NULL);
  sigaction(SIGCHLD, &action, NULL);
  return fds[0];
}

// MARK: - Lifeboat

static int lifeboat_master = -1;
static pid_t lifeboat_child = -1;
static struct termios lifeboat_termios;
static atomic_flag lifeboat_taken = ATOMIC_FLAG_INIT;
static atomic_bool lifeboat_running = false;
static char lifeboat_stack[64 * 1024];

static void lifeboat_write_all(int fd, const char *buffer, ssize_t count) {
  ssize_t offset = 0;
  while (offset < count) {
    ssize_t written = write(fd, buffer + offset, (size_t)(count - offset));
    if (written > 0) {
      offset += written;
    } else if (written < 0 && errno == EINTR) {
      continue;
    } else if (written < 0 && errno == EAGAIN) {
      // The pty master is non-blocking; wait until it accepts more.
      fd_set writable;
      FD_ZERO(&writable);
      FD_SET(fd, &writable);
      select(fd + 1, NULL, &writable, NULL, NULL);
    } else {
      return;
    }
  }
}

static void lifeboat(int sig) {
  (void)sig;
  // A second thread crashing must not start a second copy loop.
  if (atomic_flag_test_and_set(&lifeboat_taken)) {
    for (;;) pause();
  }
  atomic_store(&lifeboat_running, true);

  // Fatal signals are blocked while their handler runs; this loop never returns, so let any
  // further faults on other threads reach the guard above instead of killing the process.
  sigset_t empty;
  sigemptyset(&empty);
  pthread_sigmask(SIG_SETMASK, &empty, NULL);

  static char buffer[16 * 1024];
  struct winsize last;
  memset(&last, 0, sizeof(last));
  bool input_open = true;

  for (;;) {
    // Window size changes arrive as SIGWINCH, which cannot be relied on here, so poll for them.
    struct winsize now;
    if (ioctl(STDIN_FILENO, TIOCGWINSZ, &now) == 0 && memcmp(&now, &last, sizeof(now)) != 0) {
      ioctl(lifeboat_master, TIOCSWINSZ, &now);
      last = now;
    }

    fd_set readable;
    FD_ZERO(&readable);
    FD_SET(lifeboat_master, &readable);
    if (input_open) FD_SET(STDIN_FILENO, &readable);
    struct timeval timeout = {0, 250 * 1000};
    int highest = lifeboat_master > STDIN_FILENO ? lifeboat_master : STDIN_FILENO;
    int ready = select(highest + 1, &readable, NULL, NULL, &timeout);
    if (ready < 0 && errno != EINTR) break;
    if (ready <= 0) continue;

    if (FD_ISSET(lifeboat_master, &readable)) {
      ssize_t count = read(lifeboat_master, buffer, sizeof(buffer));
      if (count > 0) {
        lifeboat_write_all(STDOUT_FILENO, buffer, count);
      } else if (count == 0 || (errno != EINTR && errno != EAGAIN)) {
        break; // The shell is gone.
      }
    }
    if (input_open && FD_ISSET(STDIN_FILENO, &readable)) {
      ssize_t count = read(STDIN_FILENO, buffer, sizeof(buffer));
      if (count > 0) {
        lifeboat_write_all(lifeboat_master, buffer, count);
      } else if (count == 0 || (errno != EINTR && errno != EAGAIN)) {
        input_open = false;
      }
    }
  }

  tcsetattr(STDIN_FILENO, TCSANOW, &lifeboat_termios);
  int status = 0;
  int code = 1;
  if (waitpid(lifeboat_child, &status, 0) == lifeboat_child) {
    code = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
  }
  _exit(code);
}

void figo_lifeboat_arm(int master, pid_t child, const struct termios *original) {
  lifeboat_master = master;
  lifeboat_child = child;
  lifeboat_termios = *original;

  // A stack overflow leaves no room to run a handler on the faulting stack.
  stack_t stack;
  stack.ss_sp = lifeboat_stack;
  stack.ss_size = sizeof(lifeboat_stack);
  stack.ss_flags = 0;
  sigaltstack(&stack, NULL);

  struct sigaction action;
  memset(&action, 0, sizeof(action));
  action.sa_handler = lifeboat;
  action.sa_flags = SA_ONSTACK | SA_NODEFER;
  sigemptyset(&action.sa_mask);
  int fatal[] = {SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE};
  for (size_t i = 0; i < sizeof(fatal) / sizeof(fatal[0]); i++) {
    sigaction(fatal[i], &action, NULL);
  }
}

bool figo_lifeboat_active(void) {
  return atomic_load(&lifeboat_running);
}
