#!/usr/bin/env python3
"""Finite open-loop HTTP load driver using only the Python standard library."""

import argparse
from collections import deque
from dataclasses import dataclass
from datetime import datetime, timezone
import json
import math
import multiprocessing
from multiprocessing.connection import wait as wait_connections
import os
from pathlib import Path
import statistics
import tempfile
import time
from typing import Any
import urllib.error
import urllib.parse
import urllib.request


MAX_RATE = 100_000.0
MAX_DURATION = 86_400.0
MAX_WORKERS = 256
MAX_QUEUE = 1_000_000
MAX_SAMPLES = 1_000_000
MAX_TIMEOUT = 600.0
MAX_DRAIN_TIMEOUT = 600.0
MAX_RESPONSE_BYTES = 16 * 1024 * 1024


class ConfigurationError(ValueError):
    pass


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, file_pointer, code, message, headers, new_url):
        return None


@dataclass(frozen=True)
class JsonExpectation:
    pointer: str
    expected: Any


@dataclass(frozen=True)
class LoadConfig:
    url: str
    rate: float
    duration: float
    workers: int = 8
    queue_capacity: int = 1024
    timeout: float = 10.0
    drain_timeout: float = 30.0
    method: str = "GET"
    body: bytes | None = None
    headers: tuple[tuple[str, str], ...] = ()
    expected_statuses: tuple[int, ...] = (200,)
    require_json: bool = False
    json_expectations: tuple[JsonExpectation, ...] = ()
    max_response_bytes: int = 1024 * 1024


@dataclass(frozen=True)
class Outcome:
    latency_ms: float
    status: int | None
    error_kind: str | None


def strict_json_loads(value: str | bytes) -> Any:
    def invalid_constant(constant):
        raise ValueError(f"invalid JSON constant: {constant}")

    return json.loads(value, parse_constant=invalid_constant)


def validate_url(value: str) -> str:
    if not value or any(ord(character) <= 0x20 for character in value):
        raise ConfigurationError("target URL must not contain whitespace or controls")
    try:
        parsed = urllib.parse.urlsplit(value)
        _ = parsed.port
    except ValueError as error:
        raise ConfigurationError("target URL has an invalid port or host") from error
    if parsed.scheme not in ("http", "https"):
        raise ConfigurationError("target URL must use http or https")
    if not parsed.hostname:
        raise ConfigurationError("target URL must include a host")
    if parsed.username is not None or parsed.password is not None:
        raise ConfigurationError("target URL must not include credentials")
    if parsed.fragment:
        raise ConfigurationError("target URL must not include a fragment")
    path = parsed.path or "/"
    return urllib.parse.urlunsplit((parsed.scheme, parsed.netloc, path, parsed.query, ""))


def validate_config(config: LoadConfig) -> LoadConfig:
    normalized_url = validate_url(config.url)
    if not math.isfinite(config.rate) or not 0 < config.rate <= MAX_RATE:
        raise ConfigurationError(f"rate must be greater than 0 and at most {MAX_RATE:g}")
    if not math.isfinite(config.duration) or not 0 < config.duration <= MAX_DURATION:
        raise ConfigurationError(
            f"duration must be greater than 0 and at most {MAX_DURATION:g} seconds")
    if not 1 <= config.workers <= MAX_WORKERS:
        raise ConfigurationError(f"workers must be between 1 and {MAX_WORKERS}")
    if not 1 <= config.queue_capacity <= MAX_QUEUE:
        raise ConfigurationError(f"queue must be between 1 and {MAX_QUEUE}")
    if not math.isfinite(config.timeout) or config.timeout <= 0:
        raise ConfigurationError("timeout must be a finite positive number")
    if config.timeout > MAX_TIMEOUT:
        raise ConfigurationError(f"timeout must be at most {MAX_TIMEOUT:g} seconds")
    if not math.isfinite(config.drain_timeout) or not 0 < config.drain_timeout <= MAX_DRAIN_TIMEOUT:
        raise ConfigurationError(
            f"drain timeout must be greater than 0 and at most {MAX_DRAIN_TIMEOUT:g} seconds")
    offer_count = max(1, math.ceil(config.rate * config.duration - 1e-12))
    if offer_count > MAX_SAMPLES:
        raise ConfigurationError(
            f"rate and duration may offer at most {MAX_SAMPLES} requests")
    if not 1 <= config.max_response_bytes <= MAX_RESPONSE_BYTES:
        raise ConfigurationError(
            f"max response bytes must be between 1 and {MAX_RESPONSE_BYTES}")
    method = config.method.upper()
    if not method or any(character not in "ABCDEFGHIJKLMNOPQRSTUVWXYZ" for character in method):
        raise ConfigurationError("method must be an ASCII uppercase token")
    if not config.expected_statuses:
        raise ConfigurationError("at least one expected status is required")
    if any(status < 100 or status > 599 for status in config.expected_statuses):
        raise ConfigurationError("expected statuses must be between 100 and 599")
    header_names = set()
    forbidden = {"connection", "content-length", "host", "transfer-encoding"}
    for name, value in config.headers:
        lowered = name.lower()
        if (not name or lowered in header_names or lowered in forbidden
                or any(character in name for character in "\r\n:")
                or any(character in value for character in "\r\n\0")):
            raise ConfigurationError("headers must be unique, safe, and not control framing")
        header_names.add(lowered)
    for expectation in config.json_expectations:
        if expectation.pointer and not expectation.pointer.startswith("/"):
            raise ConfigurationError("JSON pointers must be empty or start with /")
    return LoadConfig(
        url=normalized_url,
        rate=config.rate,
        duration=config.duration,
        workers=config.workers,
        queue_capacity=config.queue_capacity,
        timeout=config.timeout,
        drain_timeout=config.drain_timeout,
        method=method,
        body=config.body,
        headers=config.headers,
        expected_statuses=tuple(sorted(set(config.expected_statuses))),
        require_json=config.require_json,
        json_expectations=config.json_expectations,
        max_response_bytes=config.max_response_bytes,
    )


def resolve_json_pointer(document: Any, pointer: str) -> Any:
    if pointer == "":
        return document
    if not pointer.startswith("/"):
        raise KeyError(pointer)
    current = document
    for encoded in pointer[1:].split("/"):
        token = encoded.replace("~1", "/").replace("~0", "~")
        if isinstance(current, dict):
            current = current[token]
        elif isinstance(current, list):
            if not token.isdecimal() or (len(token) > 1 and token.startswith("0")):
                raise KeyError(pointer)
            current = current[int(token)]
        else:
            raise KeyError(pointer)
    return current


def json_equal(actual: Any, expected: Any) -> bool:
    compact = {"sort_keys": True, "separators": (",", ":"), "ensure_ascii": False}
    return json.dumps(actual, **compact) == json.dumps(expected, **compact)


def validate_response(config: LoadConfig, status: int, body: bytes) -> str | None:
    if status not in config.expected_statuses:
        return "status"
    if not config.require_json and not config.json_expectations:
        return None
    try:
        document = strict_json_loads(body)
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError):
        return "json"
    for expectation in config.json_expectations:
        try:
            actual = resolve_json_pointer(document, expectation.pointer)
        except (KeyError, IndexError):
            return "json"
        if not json_equal(actual, expectation.expected):
            return "json"
    return None


def execute_request(config: LoadConfig, opener) -> Outcome:
    headers = dict(config.headers)
    headers.setdefault("User-Agent", "stiff-load/1")
    request = urllib.request.Request(
        config.url, data=config.body, headers=headers, method=config.method)
    started = time.monotonic()
    try:
        try:
            response = opener.open(request, timeout=config.timeout)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            status = response.status
            body = response.read(config.max_response_bytes + 1)
        latency_ms = (time.monotonic() - started) * 1000
        if len(body) > config.max_response_bytes:
            return Outcome(latency_ms, status, "response_too_large")
        return Outcome(latency_ms, status, validate_response(config, status, body))
    except urllib.error.URLError as error:
        kind = "timeout" if isinstance(error.reason, TimeoutError) else "transport"
        return Outcome((time.monotonic() - started) * 1000, None, kind)
    except TimeoutError:
        return Outcome((time.monotonic() - started) * 1000, None, "timeout")
    except OSError:
        return Outcome((time.monotonic() - started) * 1000, None, "transport")
    except Exception:
        return Outcome((time.monotonic() - started) * 1000, None, "internal")


def percentile(values: list[float], fraction: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    return ordered[max(0, math.ceil(len(ordered) * fraction) - 1)]


def measurement(values: list[float]) -> dict[str, float | int | None]:
    if not values:
        return {"count": 0, "min": None, "mean": None, "p50": None,
                "p95": None, "p99": None, "max": None}
    return {
        "count": len(values),
        "min": min(values),
        "mean": statistics.fmean(values),
        "p50": percentile(values, 0.50),
        "p95": percentile(values, 0.95),
        "p99": percentile(values, 0.99),
        "max": max(values),
    }


def _process_worker(number, generation, channel, config):
    """One killable request worker; messages contain primitives for safe IPC."""
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    try:
        while True:
            sequence = channel.recv()
            if sequence is None:
                return
            outcome = execute_request(config, opener)
            channel.send((number, generation, sequence, outcome.latency_ms,
                          outcome.status, outcome.error_kind))
    finally:
        channel.close()


def run_load(unchecked: LoadConfig) -> dict[str, Any]:
    config = validate_config(unchecked)
    try:
        context = multiprocessing.get_context("fork")
    except ValueError as error:
        raise ConfigurationError("load workers require a platform with fork support") from error
    waiting = deque()
    collected: list[Outcome] = []
    slots: list[dict[str, Any]] = []

    def start_slot(number, generation=0):
        parent_channel, child_channel = context.Pipe(duplex=True)
        process = context.Process(
            target=_process_worker,
            args=(number, generation, child_channel, config),
            name=f"stiff-load-{number}-{generation}")
        try:
            process.start()
        except Exception:
            parent_channel.close()
            child_channel.close()
            raise
        child_channel.close()
        return {"process": process, "channel": parent_channel,
                "generation": generation, "active": None}

    def stop_slot(slot, graceful=False):
        process = slot["process"]
        channel = slot["channel"]
        if graceful and process.is_alive():
            try:
                channel.send(None)
            except (BrokenPipeError, EOFError, OSError):
                pass
            process.join(timeout=1)
        if process.is_alive():
            process.terminate()
            process.join(timeout=2)
        if process.is_alive():
            process.kill()
            process.join(timeout=2)
        alive = process.is_alive()
        channel.close()
        if not alive:
            process.close()
        if alive:
            raise RuntimeError(f"load worker {process.pid} could not be reaped after SIGKILL")

    def replace_slot(number):
        old = slots[number]
        generation = old["generation"] + 1
        stop_slot(old)
        slots[number] = start_slot(number, generation)

    def dispatch(number, sequence, now):
        slot = slots[number]
        slot["channel"].send(sequence)
        slot["active"] = (sequence, now, now + config.timeout)

    def dispatch_waiting(now):
        for number, slot in enumerate(slots):
            if not waiting:
                return
            if slot["active"] is None:
                dispatch(number, waiting.popleft(), now)

    def handle_event(event, now):
        number, generation, sequence, latency, status, error_kind = event
        slot = slots[number]
        active = slot["active"]
        if generation != slot["generation"] or active is None or active[0] != sequence:
            return
        collected.append(Outcome(latency, status, error_kind))
        slot["active"] = None
        dispatch_waiting(now)

    def receive(timeout):
        channels = [slot["channel"] for slot in slots]
        ready = wait_connections(channels, timeout=timeout)
        now = time.monotonic()
        for channel in ready:
            number = next(index for index, slot in enumerate(slots)
                          if slot["channel"] is channel)
            try:
                event = channel.recv()
            except (EOFError, OSError):
                active = slots[number]["active"]
                if active is not None:
                    collected.append(Outcome((now - active[1]) * 1000, None, "internal"))
                replace_slot(number)
                continue
            handle_event(event, now)

    def service_once(until):
        now = time.monotonic()
        receive(0)
        for number, slot in enumerate(list(slots)):
            active = slot["active"]
            if active is not None and active[2] <= now:
                collected.append(Outcome((now - active[1]) * 1000, None, "timeout"))
                replace_slot(number)
        dispatch_waiting(now)
        if now >= until:
            return
        deadlines = [slot["active"][2] for slot in slots if slot["active"] is not None]
        wake = min([until, now + 0.02, *deadlines])
        receive(max(0.0, wake - now))

    def service_until(until):
        while time.monotonic() < until:
            service_once(until)
        service_once(until)

    forced_shutdown = True
    try:
        for number in range(config.workers):
            slots.append(start_slot(number))
        started_wall = datetime.now(timezone.utc).isoformat()
        started = time.monotonic()
        deadline = started + config.duration
        offered = 0
        accepted = 0
        dropped = 0
        schedule_lag_ms = []
        offer_count = max(1, math.ceil(config.rate * config.duration - 1e-12))
        for sequence in range(offer_count):
            due = started + sequence / config.rate
            if due >= deadline:
                break
            service_until(due)
            now = time.monotonic()
            if now >= deadline:
                break
            schedule_lag_ms.append(max(0.0, (now - due) * 1000))
            offered += 1
            idle = next((number for number, slot in enumerate(slots)
                         if slot["active"] is None), None)
            if idle is not None:
                dispatch(idle, sequence, now)
                accepted += 1
            elif len(waiting) < config.queue_capacity:
                waiting.append(sequence)
                accepted += 1
            else:
                dropped += 1
        service_until(deadline)
        offering_finished = time.monotonic()
        drain_deadline = offering_finished + config.drain_timeout
        while (waiting or any(slot["active"] is not None for slot in slots)) \
                and time.monotonic() < drain_deadline:
            service_once(drain_deadline)
        service_once(min(time.monotonic(), drain_deadline))

        forced_shutdown = bool(waiting or any(slot["active"] is not None for slot in slots))
        now = time.monotonic()
        for slot in slots:
            active = slot["active"]
            if active is not None:
                collected.append(Outcome((now - active[1]) * 1000, None, "drain_timeout"))
                slot["active"] = None
        while waiting:
            waiting.popleft()
            collected.append(Outcome(0.0, None, "drain_timeout"))
        finished = time.monotonic()
    finally:
        cleanup_errors = []
        for slot in slots:
            try:
                stop_slot(slot, graceful=not forced_shutdown and slot["active"] is None)
            except RuntimeError as error:
                cleanup_errors.append(error)
        if cleanup_errors:
            raise RuntimeError("one or more load workers could not be reaped") from cleanup_errors[0]

    errors = sum(outcome.error_kind is not None for outcome in collected)
    error_kinds = {kind: sum(outcome.error_kind == kind for outcome in collected)
                   for kind in ("timeout", "drain_timeout", "transport", "status", "json",
                                "response_too_large", "internal")}
    status_counts: dict[str, int] = {}
    for outcome in collected:
        if outcome.status is not None:
            key = str(outcome.status)
            status_counts[key] = status_counts.get(key, 0) + 1
    offering_elapsed = offering_finished - started
    total_elapsed = finished - started
    return {
        "schema_version": 1,
        "started_at": started_wall,
        "target": config.url,
        "request": {
            "method": config.method,
            "expected_statuses": list(config.expected_statuses),
            "requires_json": config.require_json or bool(config.json_expectations),
            "json_expectation_count": len(config.json_expectations),
            "max_response_bytes": config.max_response_bytes,
        },
        "load": {
            "rate_per_second": config.rate,
            "duration_seconds": config.duration,
            "workers": config.workers,
            "queue_capacity": config.queue_capacity,
            "timeout_seconds": config.timeout,
            "drain_timeout_seconds": config.drain_timeout,
            "max_offered_samples": MAX_SAMPLES,
        },
        "timing": {
            "offering_elapsed_seconds": offering_elapsed,
            "total_elapsed_seconds": total_elapsed,
            "actual_offer_rate": offered / offering_elapsed if offering_elapsed else None,
            "actual_completion_rate": len(collected) / total_elapsed if total_elapsed else None,
        },
        "counts": {
            "offered": offered,
            "accepted": accepted,
            "completed": len(collected),
            "succeeded": len(collected) - errors,
            "dropped": dropped,
            "errors": errors,
            **{f"{kind}_errors": count for kind, count in error_kinds.items()},
        },
        "statuses": status_counts,
        "latency_ms": measurement([outcome.latency_ms for outcome in collected]),
        "schedule_lag_ms": measurement(schedule_lag_ms),
    }


def parse_header(value: str) -> tuple[str, str]:
    if ":" not in value:
        raise argparse.ArgumentTypeError("header must be NAME:VALUE")
    name, content = value.split(":", 1)
    return name.strip(), content.strip()


def parse_expectation(value: str) -> JsonExpectation:
    if "=" not in value:
        raise argparse.ArgumentTypeError("JSON expectation must be POINTER=JSON")
    pointer, expected = value.split("=", 1)
    try:
        parsed = strict_json_loads(expected)
    except (json.JSONDecodeError, ValueError) as error:
        raise argparse.ArgumentTypeError("expected value must be strict JSON") from error
    return JsonExpectation(pointer, parsed)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--url", required=True, help="absolute HTTP(S) target URL")
    result.add_argument("--rate", required=True, type=float, help="offered requests per second")
    result.add_argument("--duration", required=True, type=float, help="finite offering duration in seconds")
    result.add_argument("--workers", type=int, default=8)
    result.add_argument("--queue", dest="queue_capacity", type=int, default=1024)
    result.add_argument("--timeout", type=float, default=10.0,
                        help="absolute whole-request timeout in seconds")
    result.add_argument("--drain-timeout", type=float, default=30.0,
                        help="maximum final drain time in seconds")
    result.add_argument("--method", default="GET")
    body = result.add_mutually_exclusive_group()
    body.add_argument("--body", help="UTF-8 request body")
    body.add_argument("--json-body", help="strict JSON request body")
    result.add_argument("--header", action="append", default=[], type=parse_header)
    result.add_argument("--expect-status", action="append", type=int)
    result.add_argument("--require-json", action="store_true")
    result.add_argument("--expect-json", action="append", default=[], type=parse_expectation,
                        metavar="POINTER=JSON")
    result.add_argument("--max-response-bytes", type=int, default=1024 * 1024)
    result.add_argument("--output", type=Path)
    result.add_argument("--allow-drops", action="store_true")
    result.add_argument("--allow-errors", action="store_true")
    return result


def write_report(path: Path, report: dict[str, Any]):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", dir=path.parent, prefix=path.name + ".",
                                     delete=False) as output:
        json.dump(report, output, indent=2, sort_keys=True)
        output.write("\n")
        temporary = output.name
    os.replace(temporary, path)


def main(argv=None) -> int:
    arguments = parser().parse_args(argv)
    headers = list(arguments.header)
    body = arguments.body.encode() if arguments.body is not None else None
    if arguments.json_body is not None:
        try:
            document = strict_json_loads(arguments.json_body)
        except (json.JSONDecodeError, ValueError) as error:
            parser().error(f"--json-body must be strict JSON: {error}")
        body = json.dumps(document, separators=(",", ":"), ensure_ascii=False).encode()
        if not any(name.lower() == "content-type" for name, _ in headers):
            headers.append(("Content-Type", "application/json"))
    try:
        report = run_load(LoadConfig(
            url=arguments.url,
            rate=arguments.rate,
            duration=arguments.duration,
            workers=arguments.workers,
            queue_capacity=arguments.queue_capacity,
            timeout=arguments.timeout,
            drain_timeout=arguments.drain_timeout,
            method=arguments.method,
            body=body,
            headers=tuple(headers),
            expected_statuses=tuple(arguments.expect_status or (200,)),
            require_json=arguments.require_json,
            json_expectations=tuple(arguments.expect_json),
            max_response_bytes=arguments.max_response_bytes,
        ))
    except ConfigurationError as error:
        parser().error(str(error))
    if arguments.output:
        write_report(arguments.output, report)
    print(json.dumps(report, indent=2, sort_keys=True))
    counts = report["counts"]
    failed = ((counts["dropped"] and not arguments.allow_drops)
              or (counts["errors"] and not arguments.allow_errors))
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
