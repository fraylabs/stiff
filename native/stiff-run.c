/* Native process boundary: cancellation, CPU/address-space limits and bounded logs.
 * No shell, restart or retry. See docs/execution.md for scope and exit codes. */
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#ifndef STIFF_FCNTL
#define STIFF_FCNTL fcntl
#endif
#ifndef STIFF_TEST_OBSERVE_CHILDREN
#define STIFF_TEST_OBSERVE_CHILDREN(sink, child) ((void)0)
#endif

static volatile sig_atomic_t interrupted;
static void interrupt(int sig) { interrupted = sig; }
static uint64_t now_ms(void) {
  struct timespec t;
  if (clock_gettime(CLOCK_MONOTONIC, &t)) _exit(125);
  return (uint64_t)t.tv_sec * 1000 + (uint64_t)t.tv_nsec / 1000000;
}
static unsigned long number(const char *s) {
  char *end; errno = 0;
  if (!s[0] || s[0] == '-') { fprintf(stderr, "invalid limit\n"); exit(125); }
  unsigned long n = strtoul(s, &end, 10);
  if (errno || *end || !n || n > 2147483647UL) { fprintf(stderr, "invalid limit\n"); exit(125); }
  return n;
}
static void limit(int resource, rlim_t n) {
  struct rlimit r = {n, n};
  if (setrlimit(resource, &r)) { perror("setrlimit"); _exit(125); }
}
static int nonblock(int fd) {
  int flags;
  do flags = STIFF_FCNTL(fd, F_GETFL); while (flags == -1 && errno == EINTR);
  if (flags == -1) return -1;
  int result;
  do result = STIFF_FCNTL(fd, F_SETFL, flags | O_NONBLOCK);
  while (result == -1 && errno == EINTR);
  return result;
}
static pid_t wait_retry(pid_t pid, int *status, int options) {
  pid_t result;
  do result = waitpid(pid, status, options); while (result < 0 && errno == EINTR);
  return result;
}
static void kill_reap(pid_t pid, int process_group) {
  if (pid <= 0) return;
  if (process_group) kill(-pid, SIGKILL);
  kill(pid, SIGKILL);
  wait_retry(pid, NULL, 0);
}
static int setup_failure(const char *operation, int saved_errno, pid_t child, pid_t sink,
                         int capture_read, int capture_write, int output_write) {
  if (capture_read >= 0) close(capture_read);
  if (capture_write >= 0) close(capture_write);
  if (output_write >= 0) close(output_write);
  kill_reap(child, 1);
  kill_reap(sink, 0);
  errno = saved_errno;
  perror(operation);
  return 125;
}
static void logger(int fd) {
  char buf[4096]; ssize_t n;
  while ((n = read(fd, buf, sizeof buf)) != 0) {
    if (n < 0) { if (errno == EINTR) continue; break; }
    ssize_t at = 0;
    while (at < n) {
      ssize_t m = write(STDERR_FILENO, buf + at, (size_t)(n - at));
      if (m < 0 && errno == EINTR) continue;
      if (m <= 0) _exit(0);
      at += m;
    }
  }
  _exit(0);
}
typedef struct {
  char line[4096];
  size_t used, capacity;
  int overflow;
  uint64_t dropped;
} LogBuffer;
static ssize_t drain_logs(int input, int output, LogBuffer *log) {
  char chunk[4096];
  ssize_t n = read(input, chunk, sizeof chunk);
  if (n <= 0) return n;
  for (ssize_t k = 0; k < n; k++) {
    if (!log->overflow && log->used < log->capacity) log->line[log->used++] = chunk[k];
    else log->overflow = 1;
    if (chunk[k] == '\n') {
      if (log->overflow || write(output, log->line, log->used) != (ssize_t)log->used)
        if (log->dropped < UINT64_MAX) log->dropped++;
      log->used = 0; log->overflow = 0;
    }
  }
  return n;
}
int main(int argc, char **argv) {
  unsigned long wall = 0, cpu = 0, memory = 0, grace = 500;
  int i = 1;
  for (; i < argc && strcmp(argv[i], "--"); i += 2) {
    if (i + 1 == argc) break;
    if (!strcmp(argv[i], "--wall-ms")) wall = number(argv[i+1]);
    else if (!strcmp(argv[i], "--cpu-seconds")) cpu = number(argv[i+1]);
    else if (!strcmp(argv[i], "--address-space-mb")) memory = number(argv[i+1]);
    else if (!strcmp(argv[i], "--grace-ms")) grace = number(argv[i+1]);
    else break;
  }
  if (i == argc || strcmp(argv[i], "--") || ++i == argc) {
    fprintf(stderr, "usage: stiff-run [--wall-ms N] [--cpu-seconds N] [--address-space-mb N] [--grace-ms N] -- executable [args]\n");
    return 125;
  }
#ifndef __linux__
  if (memory) { fprintf(stderr, "hard address-space limits require Linux; use an OS/container memory boundary\n"); return 125; }
#endif
  signal(SIGPIPE, SIG_IGN);
  struct sigaction sa; memset(&sa, 0, sizeof sa); sa.sa_handler = interrupt; sigemptyset(&sa.sa_mask);
  sigaction(SIGTERM, &sa, NULL); sigaction(SIGINT, &sa, NULL);
  int capture[2], output[2];
  if (pipe(capture) || pipe(output)) { perror("pipe"); return 125; }
  pid_t sink = fork();
  if (sink < 0) { perror("fork"); return 125; }
  if (!sink) { close(capture[0]); close(capture[1]); close(output[1]); logger(output[0]); }
  close(output[0]);
  if (nonblock(output[1]))
    return setup_failure("fcntl", errno, 0, sink, capture[0], capture[1], output[1]);
  long atomic_size = fpathconf(output[1], _PC_PIPE_BUF);
  size_t capacity = atomic_size > 0 && atomic_size < 4096 ? (size_t)atomic_size : 4096;
  pid_t child = fork();
  if (child < 0)
    return setup_failure("fork", errno, 0, sink, capture[0], capture[1], output[1]);
  if (!child) {
    close(capture[0]); close(output[1]);
    signal(SIGTERM, SIG_DFL); signal(SIGINT, SIG_DFL); signal(SIGPIPE, SIG_DFL);
    if (setpgid(0, 0) || dup2(capture[1], STDERR_FILENO) < 0) _exit(125);
    close(capture[1]);
    limit(RLIMIT_CORE, 0);
    if (cpu) limit(RLIMIT_CPU, (rlim_t)cpu);
#ifdef __linux__
    if (memory) limit(RLIMIT_AS, (rlim_t)memory * 1024 * 1024);
#endif
    execvp(argv[i], argv+i); perror("exec"); _exit(125);
  }
  setpgid(child, child);
  STIFF_TEST_OBSERVE_CHILDREN(sink, child);
  close(capture[1]);
  if (nonblock(capture[0]))
    return setup_failure("fcntl", errno, child, sink, capture[0], -1, output[1]);
  uint64_t start = now_ms(), deadline = 0;
  int stopped = 0, stop_signal = 0, timed_out = 0, status = 0;
  LogBuffer log = {.capacity = capacity};
  for (;;) {
    /* Completion observed before cancellation keeps its actual terminal status. */
    pid_t result = wait_retry(child, &status, WNOHANG);
    if (result == child) break;
    if (result < 0 && errno != EINTR) { status = 125 << 8; break; }
    uint64_t now = now_ms();
    if (!stopped && (interrupted || (wall && now-start >= wall))) {
      stopped = 1; stop_signal = interrupted; timed_out = !stop_signal; deadline = now + grace;
      kill(-child, SIGTERM);
    }
    if (stopped && now >= deadline) kill(-child, SIGKILL);
    struct pollfd p = {capture[0], POLLIN, 0};
    poll(&p, 1, 10);
    /* Bounded per-tick drain prevents a noisy child starving cancellation. */
    for (int batch = 0; batch < 16; batch++)
      if (drain_logs(capture[0], output[1], &log) <= 0) break;
  }
  /* Kill remaining group members, then account for the bounded pipe tail. */
  kill(-child, SIGKILL);
  uint64_t tail_deadline = now_ms() + 100;
  size_t tail_bytes = 0;
  while (now_ms() < tail_deadline && tail_bytes < 1024 * 1024) {
    ssize_t n = drain_logs(capture[0], output[1], &log);
    if (!n) break;
    if (n > 0) { tail_bytes += (size_t)n; continue; }
    if (errno != EAGAIN && errno != EINTR) break;
    struct pollfd p = {capture[0], POLLIN, 0};
    poll(&p, 1, 1);
  }
  if ((log.used || log.overflow) && log.dropped < UINT64_MAX) log.dropped++;
  char summary[180];
  int len = snprintf(summary, sizeof summary, "{\"event\":\"stiff_runner_exit\",\"dropped_log_records\":%llu,\"cancelled\":%s,\"timed_out\":%s}\n",
    (unsigned long long)log.dropped, stop_signal ? "true" : "false", timed_out ? "true" : "false");
  uint64_t sink_deadline = now_ms() + grace;
  while (write(output[1], summary, (size_t)len) != len) {
    if ((errno != EAGAIN && errno != EINTR) || now_ms() >= sink_deadline) break;
    struct pollfd p = {output[1], POLLOUT, 0};
    poll(&p, 1, 1);
  }
  close(output[1]); close(capture[0]);
  for (;;) {
    pid_t result = wait_retry(sink, NULL, WNOHANG);
    if (result == sink || (result < 0 && errno != EINTR)) break;
    if (now_ms() >= sink_deadline) { kill_reap(sink, 0); break; }
    struct timespec nap = {0, 1000000}; nanosleep(&nap, NULL);
  }
  if (timed_out) return 124;
  if (stop_signal) return 128 + stop_signal;
  if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
  return WIFEXITED(status) ? WEXITSTATUS(status) : 125;
}
