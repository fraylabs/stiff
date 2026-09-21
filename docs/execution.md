# Execution boundaries

`make runner` builds `stiff-run`, a native C process supervisor. It invokes the
executable directly (no shell), never restarts it, and never retries an effect.
Use one process for each independently cancellable job; use a service process
when cancellation is intended to stop the entire service.

```sh
make runner
./.cache/native/stiff-run --wall-ms 30000 --cpu-seconds 10 --grace-ms 500 -- \
  ./.cache/native/get-json --threads 1 https://your-api.example/resource
```

SIGTERM/SIGINT forwards graceful termination to the child process group, then
SIGKILL after the grace deadline. A wall deadline follows the same sequence.
Cancellation interrupts an already running HTTP effect, including code that
cannot reach a cooperative checkpoint. Descendants in that process group are
killed when the direct child exits. This is a trusted application boundary, not
a sandbox for hostile programs that deliberately escape their process group.
The supervisor must itself remain alive; an external service manager/container
must own cleanup if the supervisor is forcibly killed.

Exit codes: the child's ordinary status is preserved; signal exits are 128 plus
signal number; wall expiry is 124; launcher/configuration failures are 125.
SIGTERM/SIGINT cancellation returns 143/130. These reserved numbers can also be
returned by a child, so callers requiring an unambiguous audit trail should
record the action that they initiated.

## Hard resource limits

`--cpu-seconds N` uses the OS hard RLIMIT_CPU for each process, not a cooperative
time check. It limits accumulated CPU time, not instantaneous utilization or the
sum across forked processes. `--wall-ms N` is a monotonic elapsed-time deadline
plus the specified termination grace and OS scheduling delay. A process stuck
in uninterruptible kernel I/O can outlive SIGKILL until that I/O completes; the
supervisor waits to reap it. This is not a hard real-time termination guarantee.

Linux `--address-space-mb N` uses hard RLIMIT_AS. macOS rejects the option rather
than pretending its address-space limit is reliably enforced. This limits virtual
address space, **not resident memory**. Bend reserves an 8 GiB arena and large
per-worker virtual stacks; choose an appropriate address-space budget and explicit
`--threads`, and verify startup under that budget. ASan also needs a large shadow
address space; small RLIMIT_AS budgets are unsuitable for sanitizer executables.
For a hard resident-memory boundary on Linux, use a cgroup (`MemoryMax` in the
[systemd example](../examples/deploy/stiff.service), or your container runtime's
memory limit). macOS development does not claim that production memory contract.
No resources or services are installed by these examples.

## Bounded stderr handling

The supervisor drains application stderr into a bounded pipe to a separate logger
process. Whole newline-terminated records up to the pipe's atomic-write limit
(at most 4096 bytes) are forwarded; oversized records and records that cannot fit
immediately are dropped. A slow/failed stderr sink cannot hold up the application
or keep shutdown waiting indefinitely. The logger receives at most one grace
period to finish on exit. Delivery is best effort: a crash, a permanently failed
sink, or logger termination can lose buffered records. This is diagnostic logging,
not an audit journal. stdout remains the application's own blocking stream.

A final best-effort JSON `stiff_runner_exit` record includes the supervisor's
observed dropped-record count, cancellation, and timeout. This cannot count records
lost downstream or guarantee the final record itself reaches a failed sink.
Without `stiff-run`, `App.observe` still writes synchronously to stderr; use this
process boundary (or an equivalent bounded collector) in a deployed service.

## Interrupted operations

Killing a process does not roll back an HTTP request that reached another system.
Treat its outcome as unknown; reconcile with that system using its operation ID
before retrying. The SQLite store's idempotency contract covers its own atomic
local mutation and recorded result only. It does not make arbitrary remote effects
exactly once. Per-handler cooperative `Server.active` checks remain useful inside
a multi-request service; they do not provide preemptive cancellation of one Bend
task. Use a separate supervised process for that isolation requirement.
