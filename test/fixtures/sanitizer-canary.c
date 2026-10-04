// Deliberate faults used ONLY by test_sanitizers.py to verify instrumentation.
#include <limits.h>
static Term probe_check_run(Env e, Term* fields, IoWork* work) {
  (void)e; (void)work;
  if (fields[0] == 1) {
    volatile int maximum = INT_MAX;
    volatile int overflow = maximum + 1;
    (void)overflow;
  } else {
    volatile int* value = io_mem(malloc(sizeof(int)));
    value[1] = 42;
    free((void*)value);
  }
  return term_pak(CID(Unit), 0);
}
static void __attribute__((constructor)) probe_check_register(void) {
  io_eff(CID(Probe.check), probe_check_run, 0);
}
