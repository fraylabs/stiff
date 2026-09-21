#!/usr/bin/env python3
"""Bounded loopback measurements, not a production capacity certification."""
import argparse
import concurrent.futures
import hashlib
import http.client
import json
import math
import os
from pathlib import Path
import platform
import queue
import shutil
import signal
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parent.parent
REQUEST_TIMEOUT = 5
PAYLOAD = {"text": "x" * 1024, "items": [1, True, None, "🌱"]}
BODY = json.dumps(PAYLOAD, separators=(",", ":"), ensure_ascii=False).encode()
# Exact bounded histogram: upper bounds in milliseconds, final bin is overflow.
BUCKETS = 5001


def command(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True, timeout=20).strip()


def percentile(histogram, fraction):
    count = sum(histogram)
    if not count:
        return None
    target = math.ceil(count * fraction)
    seen = 0
    for bucket, number in enumerate(histogram):
        seen += number
        if seen >= target:
            return None if bucket == BUCKETS else bucket


def request(port, path):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=REQUEST_TIMEOUT)
    try:
        connection.request("POST" if path == "/echo" else "GET", path,
                           body=BODY if path == "/echo" else None,
                           headers={"Content-Type": "application/json"} if path == "/echo" else {})
        response = connection.getresponse()
        body = response.read(8193)
        valid = False
        if response.status == 200:
            expected = PAYLOAD if path == "/echo" else {} if path == "/hold" else {"message": "healthy"}
            try:
                valid = len(body) <= 8192 and json.loads(body) == expected
            except (ValueError, UnicodeError):
                pass
        return response.status, valid
    finally:
        connection.close()


class Server:
    def __init__(self, executable, rss_limit_mib):
        self.lines = queue.Queue()
        self.samples = []
        self.stop_sampling = threading.Event()
        self.abort = threading.Event()
        self.memory_limit_exceeded = False
        self.sampling_errors = []
        self.limit = rss_limit_mib * 1024 * 1024
        self.started = time.monotonic()
        self.ps = shutil.which("ps")
        self.stderr = tempfile.TemporaryFile(mode="w+t")
        self.process = subprocess.Popen([str(executable)], cwd=executable.parent,
                                        env={"PATH": "/nonexistent"},
                                        stdout=subprocess.PIPE, stderr=self.stderr, text=True)
        self.reader = threading.Thread(target=self.read_lines, daemon=True)
        self.reader.start()
        self.sampler = threading.Thread(target=self.sample, daemon=True)
        self.sampler.start()
        try:
            line = self.lines.get(timeout=10)
            if not line.startswith("LISTENING "):
                raise RuntimeError("Native server did not announce its port")
            self.port = int(line.split()[1])
        except BaseException:
            self.close()
            raise

    def read_lines(self):
        for line in self.process.stdout:
            self.lines.put(line.strip())

    def rss(self):
        if platform.system() == "Linux":
            for line in Path(f"/proc/{self.process.pid}/status").read_text().splitlines():
                if line.startswith("VmRSS:"):
                    return int(line.split()[1]) * 1024
            raise RuntimeError("VmRSS unavailable")
        if platform.system() == "Darwin" and self.ps:
            result = subprocess.run([self.ps, "-o", "rss=", "-p", str(self.process.pid)],
                                    capture_output=True, text=True, timeout=2, check=True)
            return int(result.stdout.strip()) * 1024
        raise RuntimeError("RSS sampling supports macOS and Linux only")

    def sample(self):
        while not self.stop_sampling.is_set() and self.process.poll() is None:
            try:
                rss = self.rss()
                self.samples.append({"seconds": round(time.monotonic() - self.started, 3), "rss_bytes": rss})
                if rss > self.limit:
                    self.memory_limit_exceeded = True
                    self.abort.set()
                    self.process.terminate()
                    return
            except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
                if self.process.poll() is None:
                    self.sampling_errors.append(type(error).__name__)
            self.stop_sampling.wait(0.25)

    def await_holds(self, count):
        deadline = time.monotonic() + 10
        for _ in range(count):
            line = self.lines.get(timeout=max(0.01, deadline - time.monotonic()))
            if line != "HOLD":
                raise RuntimeError(f"Unexpected server lifecycle line: {line}")

    def close(self):
        forced = False
        if self.process.poll() is None:
            self.process.send_signal(signal.SIGTERM)
            try:
                self.process.wait(timeout=7)
            except subprocess.TimeoutExpired:
                forced = True
                self.process.kill()
                self.process.wait(timeout=3)
        self.stop_sampling.set()
        self.sampler.join(timeout=3)
        self.reader.join(timeout=3)
        self.process.stdout.close()
        self.stderr.seek(0)
        diagnostics = self.stderr.read()
        self.stderr.close()
        return {"exit_code": self.process.returncode, "forced_kill": forced,
                "stderr": diagnostics, "rss_limit_exceeded": self.memory_limit_exceeded,
                "rss_sampling_errors": self.sampling_errors}


def phase(server, name, path, concurrency, duration):
    deadline = time.monotonic() + duration
    started = time.monotonic()
    cpu_started = time.process_time()
    samples_start = len(server.samples)

    def worker():
        hist = [0] * (BUCKETS + 1)
        statuses = {}
        errors = {}
        valid = invalid = completed = 0
        maximum = 0
        while time.monotonic() < deadline and not server.abort.is_set():
            tick = time.monotonic()
            try:
                status, correct = request(server.port, path)
                statuses[str(status)] = statuses.get(str(status), 0) + 1
                completed += 1
                if correct:
                    valid += 1
                elif status == 200:
                    invalid += 1
            except (OSError, http.client.HTTPException) as error:
                key = type(error).__name__
                errors[key] = errors.get(key, 0) + 1
            elapsed = (time.monotonic() - tick) * 1000
            maximum = max(maximum, elapsed)
            hist[min(math.ceil(elapsed), BUCKETS)] += 1
        return hist, statuses, errors, valid, invalid, completed, maximum

    with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as pool:
        results = list(pool.map(lambda _: worker(), range(concurrency)))
    elapsed = time.monotonic() - started
    hist = [sum(row[0][i] for row in results) for i in range(BUCKETS + 1)]
    statuses, errors = {}, {}
    for row in results:
        for key, value in row[1].items():
            statuses[key] = statuses.get(key, 0) + value
        for key, value in row[2].items():
            errors[key] = errors.get(key, 0) + value
    valid = sum(row[3] for row in results)
    invalid = sum(row[4] for row in results)
    samples = server.samples[samples_start:]
    return {
        "name": name, "path": path, "concurrency": concurrency,
        "requested_seconds": duration, "elapsed_seconds": round(elapsed, 3),
        "attempts": sum(hist), "completed_responses": sum(row[5] for row in results),
        "valid_responses": valid, "invalid_200_bodies": invalid,
        "status_counts": statuses, "transport_errors": errors,
        "valid_responses_per_second": round(valid / elapsed, 2),
        "latency_ms_upper_bounds": {"p50": percentile(hist, .5), "p95": percentile(hist, .95),
                                    "p99": percentile(hist, .99)},
        "latency_overflow_count": hist[-1],
        "latency_max_ms": round(max(row[6] for row in results), 3),
        "load_generator_cpu_seconds": round(time.process_time() - cpu_started, 3),
        "rss_peak_bytes": max((s["rss_bytes"] for s in samples), default=None),
        "rss_last_bytes": samples[-1]["rss_bytes"] if samples else None,
        "correct": bool(valid) and invalid == 0 and not errors and set(statuses) == {"200"},
    }


def overload_and_shutdown(server):
    # Read actual handler-admission events before probing the full queue.
    with concurrent.futures.ThreadPoolExecutor(max_workers=32) as pool:
        holds = [pool.submit(request, server.port, "/hold") for _ in range(32)]
        server.await_holds(32)
        rejected = [request(server.port, "/health")[0] for _ in range(8)]
        drained = [future.result(timeout=6) for future in holds]
    recovery = request(server.port, "/health")
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        pending = [pool.submit(request, server.port, "/hold") for _ in range(2)]
        server.await_holds(2)
        server.process.send_signal(signal.SIGTERM)
        shutdown_replies = [future.result(timeout=6) for future in pending]
    server.process.wait(timeout=7)
    return {"overload_statuses": rejected, "admitted_valid": sum(v == (200, True) for v in drained),
            "recovered": recovery == (200, True),
            "shutdown_valid": sum(v == (200, True) for v in shutdown_replies),
            "correct": rejected == [503] * 8 and drained == [(200, True)] * 32
                       and recovery == (200, True) and shutdown_replies == [(200, True)] * 2}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--duration", type=float, default=5, help="seconds per measured workload")
    parser.add_argument("--soak-round-seconds", type=float, default=10, help="seconds in each of three JSON soak windows")
    parser.add_argument("--concurrency", type=int, nargs="+", default=[1, 8, 32])
    parser.add_argument("--rss-limit-mib", type=int, default=512)
    parser.add_argument("--output", type=Path, default=ROOT / ".cache/benchmark/report.json")
    args = parser.parse_args()
    if (not .1 <= args.duration <= 300 or not .1 <= args.soak_round_seconds <= 300
            or not 1 <= len(args.concurrency) <= 8 or any(not 1 <= n <= 32 for n in args.concurrency)
            or not 64 <= args.rss_limit_mib <= 2048):
        parser.error("durations: 0.1–300; concurrency: 1–32 (up to 8 stages); RSS limit: 64–2048 MiB")
    report = {"schema": 1, "passed": False, "phases": [], "rss_samples": []}
    exit_code = 1
    try:
        with tempfile.TemporaryDirectory(prefix="stiff-benchmark-") as temporary:
            executable = Path(temporary) / "server"
            build = subprocess.run([str(ROOT / "scripts/build-native.sh"), "benchmark/server.bend", str(executable)],
                                   cwd=ROOT, capture_output=True, text=True, timeout=120)
            if build.returncode:
                raise RuntimeError("Build failed: " + build.stdout + build.stderr)
            executable.with_suffix(".c").unlink()
            sources = sorted([ROOT / "benchmark/server.bend", ROOT / "examples/server.bend",
                              ROOT / "scripts/build-native.sh", ROOT / "scripts/benchmark.py", *ROOT.glob("src/**/*.bend"), *ROOT.glob("src/**/*.c")])
            digest = hashlib.sha256()
            for path in sources:
                digest.update(str(path.relative_to(ROOT)).encode() + b"\0" + path.read_bytes())
            report["environment"] = {
                "platform": platform.platform(), "machine": platform.machine(), "logical_cpus": os.cpu_count(),
                "python": platform.python_version(), "clang": command(os.environ.get("CC", "clang"), "--version").splitlines()[0],
                "libraries": {name: command("pkg-config", "--modversion", name) for name in ("libcurl", "json-c", "libevent")},
                "bend": command(os.environ.get("BEND", str(ROOT / ".cache/toolchain/bin/bend")), "version"),
                "git_revision": command("git", "rev-parse", "HEAD"),
                "working_tree_dirty": bool(command("git", "status", "--porcelain")),
                "source_sha256": digest.hexdigest(), "binary_sha256": hashlib.sha256(executable.read_bytes()).hexdigest(),
                "abi": os.environ.get("STIFF_NATIVE_ABI", "compiler"),
                "sanitizers": os.environ.get("STIFF_NATIVE_SANITIZE", "0"),
            }
            report["workload"] = {"payload_bytes": len(BODY), "max_pending": 32,
                                  "rss_limit_mib": args.rss_limit_mib, "request_timeout_seconds": REQUEST_TIMEOUT,
                                  "model": "closed-loop, Python stdlib client and server on same host; one connection per request"}
            server = Server(executable, args.rss_limit_mib)
            try:
                warmup = phase(server, "warmup", "/echo", max(args.concurrency), 2)
                report["warmup"] = warmup
                if not warmup["correct"]:
                    raise RuntimeError("Warmup failed correctness checks")
                for path in ("/health", "/echo"):
                    for concurrency in args.concurrency:
                        result = phase(server, f"{path[1:]}-c{concurrency}", path, concurrency, args.duration)
                        report["phases"].append(result)
                        print(json.dumps(result), flush=True)
                        if not result["correct"]:
                            raise RuntimeError("Measured phase failed correctness checks")
                for index in range(3):
                    result = phase(server, f"soak-{index + 1}", "/echo", max(args.concurrency), args.soak_round_seconds)
                    report["phases"].append(result)
                    time.sleep(.5)  # Fixed settling sample, not a claim of allocator reclamation.
                    report.setdefault("settled_rss_bytes", []).append(server.rss())
                    if not result["correct"]:
                        raise RuntimeError("Soak window failed correctness checks")
                report["overload_and_shutdown"] = overload_and_shutdown(server)
            finally:
                report["shutdown"] = server.close()
                report["rss_samples"] = server.samples
            shutdown = report["shutdown"]
            report["passed"] = (report["overload_and_shutdown"]["correct"]
                                and shutdown["exit_code"] == 0 and not shutdown["forced_kill"]
                                and not shutdown["stderr"] and not shutdown["rss_limit_exceeded"]
                                and bool(server.samples) and not shutdown["rss_sampling_errors"])
            exit_code = 0 if report["passed"] else 1
    except (Exception, KeyboardInterrupt) as error:
        report["failure"] = f"{type(error).__name__}: {error}"
    finally:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + "\n")
        print(f"Report: {args.output}", flush=True)
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
