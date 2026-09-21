#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int calls;
static int injected;

int stiff_test_fcntl(int fd, int command, ...) {
  calls++;
  const char *mode = getenv("STIFF_RUNNER_FCNTL_FAULT");
  if (calls == 3 && !injected && mode) {
    injected = 1;
    const char *path = getenv("STIFF_RUNNER_CHILDREN_FILE");
    if (path) {
      FILE *output = fopen(path, "a");
      if (output) {
        fprintf(output, "%s\n", mode);
        fclose(output);
      }
    }
    errno = !strcmp(mode, "eintr") ? EINTR : EIO;
    return -1;
  }
  if (command == F_SETFL) {
    va_list arguments;
    va_start(arguments, command);
    int flags = va_arg(arguments, int);
    va_end(arguments);
    return fcntl(fd, command, flags);
  }
  return fcntl(fd, command);
}

void stiff_test_observe_children(long sink, long child) {
  const char *path = getenv("STIFF_RUNNER_CHILDREN_FILE");
  if (!path) return;
  FILE *output = fopen(path, "w");
  if (!output) return;
  fprintf(output, "%ld %ld\n", sink, child);
  fclose(output);
}
