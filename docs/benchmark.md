# Local load and recovery measurements

Run `make setup`, then `make benchmark`. The benchmark builds a native Bend
server in a temporary directory, removes generated C and starts that executable
with no tools on PATH. It binds only `127.0.0.1` on an OS-selected port, uses
synthetic requests, and stops only its own child process. Python's standard
library supplies the load generator; it is not in the server runtime.

The default run measures health responses and JSON parse/encode echo at 1, 8
and 32 concurrent clients, five seconds per workload, after a two-second JSON
warmup. Three ten-second JSON windows follow in the same server process.
Every successful response is checked against its expected JSON value. Finally,
32 admitted slow handlers fill the pending-work limit: eight excess requests
must receive 503, all admitted requests must complete, a health request must
succeed afterward, and two admitted requests must drain through SIGTERM.

```sh
make benchmark
# Longer local soak: three sixty-second windows after the workload sweep
python3 scripts/benchmark.py --duration 3 --soak-round-seconds 60 \
  --output .cache/benchmark/extended.json
```

The JSON report defaults to `.cache/benchmark/report.json`. It records platform,
compiler/library versions, source and executable hashes, ABI/sanitizer settings,
request counts, status codes, transport failures, invalid response bodies,
validated responses per second, latency percentiles, sampled RSS and shutdown.
A source hash covers the native sources, example handler, build script and
measurement script; Git revision and dirty status provide additional context.
Normal and sanitizer builds are different profiles and must not be compared as
if they were the same executable.

Latency uses a bounded histogram with one-millisecond bins. Reported p50/p95/p99
are nearest-rank bin upper bounds; values over 5,000 ms enter an overflow bin,
whose percentile is null. Maximum observed latency and overflow count remain
visible. Latency includes connection setup, response reads and validation for
all attempts, including failures. Throughput counts only correct HTTP 200
responses and uses actual elapsed time, including the final in-flight requests.
The five-second socket timeout is an I/O timeout, not an absolute request deadline.

RSS is sampled every 250 ms using `/proc` on Linux and `ps` on macOS. Sampling
can miss short peaks. A missing sample during teardown is discarded only after
observing process exit; a still-running process with unavailable RSS fails sampling. A configurable RSS guard defaults to 512 MiB; crossing it
requests termination, marks the run failed and preserves the partial report.
This is a sampled stop condition, not a hard memory sandbox. The JSON windows
also record RSS after a 500 ms settling interval. Neither a lower RSS reading
nor a clean shutdown proves absence of leaks or accounts for compressed/swapped
memory. The report does not automatically certify memory stability.

The command exits nonzero on incorrect responses, unexpected statuses or
transport failures, broken overload/recovery/shutdown behavior, abnormal process
exit, stderr diagnostics, or missing/failed RSS sampling. A passing result means
those exercised checks passed. There is deliberately no minimum throughput gate
on shared CI machines. `make test` includes a short version of this journey in
both normal and sanitizer CI profiles, plus percentile-accounting checks.

## Interpretation and remaining gaps

This is a closed-loop workload with a Python client and native server sharing
one host. Client CPU, thread scheduling, the [CPython GIL](https://docs.python.org/3.11/library/threading.html), TCP setup, ephemeral ports and
other host activity can limit the measured rate. Closed-loop latency also omits
waiting that would accumulate under an independent arrival stream
(the [coordinated omission problem](https://github.com/giltene/wrk2)). These
numbers are observations, not maximum server capacity or an external-client SLA.
The server currently closes every response connection; this is not a keep-alive,
TLS, HTTP/2 or streaming benchmark.

The fixed benchmark configuration allows 32 pending handlers, 4 KiB bodies,
five-second I/O/dispatch timeouts and three-second network shutdown grace. Current
builds also use the default 256 accepted-connection cap and five-second absolute
request-read deadline; the recorded baseline below predates those protections.
The overload check concerns complete requests admitted for dispatch; separate
server integration tests exercise slow/incomplete connections and cooperative
cancellation. Crash recovery and persistent state are not exercised here.

Before claiming production scalability, measure an independently driven arrival
rate, longer repeated soaks, varied payloads/handlers, multiple hardware targets,
and incomplete/slow-client pressure. Investigate unexplained memory trends with
allocator/runtime evidence. Keep the documented sanitizer coverage limits separate from these normal-build
measurements. The framework does not claim a universal production capacity.


## Initial observation — September 21, 2026

This historical observation predates the scoped libevent 2.2 pin and request
streaming. One local run used the extended command above, the normal compiler ABI, Bend
2.0.20, Apple Clang 21.0.0, macOS arm64 (10 logical CPUs), libevent 2.1.12,
libcurl 8.7.1 and json-c 0.19. This was a shared development machine, not a
dedicated performance host. The JSON request body was 1064 bytes.

| JSON soak window | Valid responses | Valid responses/sec | p99 upper bound | Peak sampled RSS |
| --- | ---: | ---: | ---: | ---: |
| soak-1 (60 seconds, 32 clients) | 330,916 | 5,514.92 | 24 ms | 99.4 MiB |
| soak-2 (60 seconds, 32 clients) | 334,703 | 5,578.03 | 24 ms | 175.4 MiB |
| soak-3 (60 seconds, 32 clients) | 339,363 | 5,655.71 | 23 ms | 131.2 MiB |

Across warmup, workload sweeps and soak windows, 1,115,652 responses passed
validation with no unexpected HTTP statuses or transport errors. This total
excludes the intentional overload probes and final recovery/shutdown requests.
The 32 admitted slow handlers completed; all eight excess probes received 503;
the subsequent health request succeeded; both shutdown-drain replies completed.
The server exited zero with empty stderr.

Peak sampled RSS over the entire run was 175.4 MiB.
After the three settling intervals, RSS was
22.0, 41.5, 22.2 MiB. The earlier short smoke showed rising RSS;
this longer observation did not show a monotonic rise in settled RSS. Neither
observation identifies the allocator behavior or proves leak freedom. Compressed
memory and longer workloads remain unmeasured.

The report recorded source SHA-256
`d4daac0d62cc9360df322a6e59aba3c0c99c8fa39faaf5ecdadc0b5d3b8f6ec1`
and executable SHA-256
`5ea79bf27e9e4ea6ea680800911aa184ff2b0451cf793f8a100f63d98524be34`.
The parent Git revision was `bc740b0e499049210ba908ed7096827517654801`;
the benchmark additions were in the working tree. A later harness fix verifies
process exit before discarding a missing final RSS sample during Linux teardown;
the native server and workload are unchanged. Raw local reports are ignored
under `.cache/benchmark/`; rerun the command for a fresh machine-specific report.
These observations do not establish a production capacity rating.
