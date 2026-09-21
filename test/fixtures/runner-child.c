#define _POSIX_C_SOURCE 200809L
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/resource.h>
int main(int argc, char **argv) {
  if (argc < 2) return 2;
  if (!strcmp(argv[1], "cpu")) { for (;;) { } }
  if (!strcmp(argv[1], "memory")) {
    void *p = malloc(256UL * 1024 * 1024);
    if (p) { free(p); return 1; }
    return 0;
  }
  if (!strcmp(argv[1], "resident")) {
    volatile unsigned char *p = malloc(256UL * 1024 * 1024);
    if (!p) return 4;
    for (size_t n = 0; n < 256UL * 1024 * 1024; n += 4096) p[n] = 1;
    free((void*)p);
    return 0;
  }
  if (!strcmp(argv[1], "logs")) {
    for (int i = 0; i < 100000; i++) fprintf(stderr, "{\"event\":\"test\",\"n\":%d}\n", i);
    return 0;
  }
  if (!strcmp(argv[1], "exit")) { puts("EXITING"); fflush(stdout); fprintf(stderr, "{\"event\":\"child\"}\n"); return 7; }
  if (!strcmp(argv[1], "grandchild")) {
    pid_t pid = fork();
    if (pid < 0) return 3;
    if (!pid) { signal(SIGTERM, SIG_IGN); for (;;) pause(); }
    printf("%ld\n", (long)pid); fflush(stdout);
  }
  signal(SIGTERM, SIG_IGN);
  puts("READY"); fflush(stdout);
  for (;;) pause();
}
