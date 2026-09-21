#ifndef STIFF_RUNNER_FCNTL_SHIM_H
#define STIFF_RUNNER_FCNTL_SHIM_H

int stiff_test_fcntl(int fd, int command, ...);
void stiff_test_observe_children(long sink, long child);
#define STIFF_FCNTL stiff_test_fcntl
#define STIFF_TEST_OBSERVE_CHILDREN(sink, child) \
  stiff_test_observe_children((long)(sink), (long)(child))

#endif
