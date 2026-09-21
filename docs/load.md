# Open-loop load driver

`scripts/load.py` is a finite, standard-library HTTP(S) load client. It targets a
separately started URL and never builds, starts, stops or discovers a server. Its
arrival schedule advances from monotonic time at the requested rate instead of
waiting for each response. A fixed pool of killable worker processes and a
bounded parent-side waiting queue prevent the client from creating unbounded
workers or pending work. Worker processes are an outer boundary around Python's
inactivity-based HTTP timeout: the parent enforces each request's absolute
whole-transfer deadline and reaps that worker, including its sockets, on expiry.

Build and start the app separately:

```sh
./scripts/build-native.sh examples/app.bend .cache/native/app
./.cache/native/app 127.0.0.1 8080
```

Run a 60-second health workload from another terminal:

```sh
python3 scripts/load.py \
  --url http://127.0.0.1:8080/health \
  --header 'X-Demo-Access: allowed' \
  --rate 100 --duration 60 --workers 16 --queue 512 --timeout 2 \
  --drain-timeout 10 \
  --expect-json '/status="ok"' \
  --output .cache/load/health.json
```

POST bodies and response semantics can be checked independently:

```sh
python3 scripts/load.py \
  --url http://127.0.0.1:8080/greet \
  --method POST --json-body '{"name":"Brian"}' \
  --header 'X-Demo-Access: allowed' \
  --rate 100 --duration 60 --workers 16 --queue 512 --timeout 2 \
  --expect-json '/greeting="Hello, Brian"' \
  --output .cache/load/greet.json
```

`--expect-json` is repeatable and takes an RFC 6901 JSON pointer, `=`, and a
strict JSON value. An empty pointer checks the whole response. `--require-json`
checks parsing without requiring a value. `--expect-status` is repeatable and
defaults to 200. The driver reads at most `--max-response-bytes` (1 MiB by
default), verifies TLS normally, follows no redirects and connects directly
without environment proxy settings. Target URLs must be absolute HTTP(S) URLs
without embedded credentials or fragments.

The product of rate and duration may schedule at most 1,000,000 requests. This
is also the maximum number of scheduler-lag and completion samples retained for
a run. Rate remains capped at 100,000/s, the waiting queue at 1,000,000 entries,
workers at 256, and both `--timeout` and `--drain-timeout` at 600 seconds. Invalid
combinations fail before any worker starts.

`--timeout` is measured from dispatch to a worker through response completion
and result handoff to the parent.
It is an absolute deadline, so a peer that sends one byte repeatedly cannot keep
the request alive. `--drain-timeout` bounds the entire drain after offering ends.
When it expires, active workers are terminated and queued work is cancelled;
both become completed `drain_timeout` errors in the report. All worker processes
are joined or killed before `run_load` returns, so a returned run has no load
worker continuing network activity in the background. The process boundary uses
`fork`, matching Stiff's supported macOS/Linux environments. Use the CLI from a
single-threaded controller; programmatic callers must not call `run_load` after
starting application threads. Each worker has a private pipe, so terminating one
cannot corrupt another worker's result channel. If the OS cannot reap a worker
after terminate and kill (for example, during uninterruptible kernel I/O), the
run raises an error and does not return a completed report.

## Counts and timing

The JSON report records:

- `offered`: scheduled arrivals during the finite offering window.
- `accepted`: arrivals admitted to the bounded local queue.
- `dropped`: arrivals rejected because that queue was full.
- `completed`: accepted requests that returned or failed; this must equal
  `accepted` after the final drain.
- `succeeded` and `errors`, with errors split into transport, unexpected status,
  whole-request timeout, drain timeout, JSON semantic, oversized-response and
  internal categories.
- HTTP status counts, completion latency and scheduler lag. Latency percentiles
  use nearest-rank values over all completed attempts, including failures.
- Offering and total elapsed time. Total time includes draining accepted work
  after arrivals stop; the offering schedule does not wait for that work.

An active request cancelled by the final drain records elapsed dispatch time as
its latency. Work cancelled while still queued records zero latency because no
HTTP attempt began. These synthetic terminal outcomes keep `completed` equal to
`accepted` without presenting queued cancellation as server response time.

A default command exits nonzero when any work is dropped or any completed request
fails. `--allow-drops` and `--allow-errors` change only that process verdict; the
report always retains the counts. Reports are written through a temporary file
and atomically replaced at the requested path.

Drops identify client-side admission pressure. Transport errors, HTTP overload
responses and semantic errors identify different outcomes and must not be merged
into throughput. The worker count, queue size and scheduler lag are part of the
measurement and should be retained when comparing runs.

## Interpretation limits

This is an application journey and overload/recovery tool, not a coordinated
distributed load generator or a real-time scheduler. Python process scheduling
and IPC, the local network stack, TLS setup and one connection per request
contribute to the observed numbers. A loopback run shares CPU and memory with the server and is
not a capacity claim. Use a separate load host and target environment for a
deployment measurement, preserve its exact report and validate the response
semantics appropriate to that environment.
