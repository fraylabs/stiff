"""Unit and loopback integration checks for the independent open-loop driver."""

import http.server
import importlib.util
import json
import multiprocessing
from pathlib import Path
import socket
import threading
import time
import unittest


ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("stiff_load", ROOT / "scripts/load.py")
LOAD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(LOAD)


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    trickle_lock = threading.Lock()
    trickle_writes = 0

    def log_message(self, *_args):
        pass

    def reply(self, status, body, content_type="application/json"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        if self.path == "/trickle":
            self.send_response(200)
            self.send_header("Content-Length", "100")
            self.send_header("Connection", "close")
            self.end_headers()
            for _ in range(100):
                try:
                    self.wfile.write(b"x")
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    break
                with self.trickle_lock:
                    type(self).trickle_writes += 1
                time.sleep(0.03)
        elif self.path == "/slow":
            time.sleep(0.15)
            self.reply(200, b'{"status":"slow"}')
        elif self.path == "/status":
            self.reply(503, b'{"status":"unavailable"}')
        elif self.path == "/bad-json":
            self.reply(200, b"not-json", "text/plain")
        elif self.path == "/large":
            self.reply(200, b"x" * 128, "text/plain")
        else:
            self.reply(200, b'{"status":"ok","nested":{"value":3},"items":[true]}')

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        if (self.path != "/greet" or self.headers.get("X-Demo-Access") != "allowed"
                or self.headers.get("Content-Type") != "application/json"):
            self.reply(400, b'{"error":"invalid"}')
            return
        name = json.loads(body)["name"]
        self.reply(200, json.dumps({"greeting": f"Hello, {name}"}).encode())


class LoadTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        cls.server.daemon_threads = True
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base = f"http://127.0.0.1:{cls.server.server_port}"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=2)

    def one(self, route, **changes):
        values = {
            "url": self.base + route,
            "rate": 10,
            "duration": 0.1,
            "workers": 2,
            "queue_capacity": 4,
            "timeout": 1,
        }
        values.update(changes)
        return LOAD.run_load(LOAD.LoadConfig(**values))

    def test_target_and_bound_validation(self):
        invalid = [
            "ftp://example.com/path",
            "http:///path",
            "http://user:secret@example.com/path",
            "http://example.com/path#fragment",
            "http://example.com/a b",
            "http://[::1",
        ]
        for url in invalid:
            with self.subTest(url=url), self.assertRaises(LOAD.ConfigurationError):
                LOAD.validate_config(LOAD.LoadConfig(url=url, rate=1, duration=1))
        for field, value in (("rate", 0), ("duration", 0), ("workers", 0),
                             ("queue_capacity", 0), ("timeout", 601),
                             ("drain_timeout", 0), ("max_response_bytes", 0)):
            arguments = {"url": self.base, "rate": 1, "duration": 1, field: value}
            with self.subTest(field=field), self.assertRaises(LOAD.ConfigurationError):
                LOAD.validate_config(LOAD.LoadConfig(**arguments))

    def test_json_pointer_and_strict_expected_values(self):
        document = {"a/b": {"~key": [False, 3]}}
        self.assertEqual(LOAD.resolve_json_pointer(document, "/a~1b/~0key/1"), 3)
        self.assertTrue(LOAD.json_equal(False, False))
        self.assertFalse(LOAD.json_equal(False, 0))
        with self.assertRaises(KeyError):
            LOAD.resolve_json_pointer(document, "/a~1b/~0key/01")
        with self.assertRaises(ValueError):
            LOAD.strict_json_loads("NaN")

    def test_successful_post_and_semantic_validation(self):
        report = self.one(
            "/greet",
            method="POST",
            body=b'{"name":"Brian"}',
            headers=(("Content-Type", "application/json"),
                     ("X-Demo-Access", "allowed")),
            json_expectations=(LOAD.JsonExpectation("/greeting", "Hello, Brian"),),
        )
        self.assertEqual(report["counts"], {
            "offered": 1, "accepted": 1, "completed": 1, "succeeded": 1,
            "dropped": 0, "errors": 0, "transport_errors": 0,
            "timeout_errors": 0, "drain_timeout_errors": 0,
            "status_errors": 0, "json_errors": 0,
            "response_too_large_errors": 0, "internal_errors": 0,
        })
        self.assertEqual(report["statuses"], {"200": 1})
        self.assertEqual(report["latency_ms"]["count"], 1)

    def test_status_json_size_and_transport_failures_are_distinct(self):
        status = self.one("/status")
        self.assertEqual((status["counts"]["errors"], status["counts"]["status_errors"]),
                         (1, 1))
        invalid_json = self.one("/bad-json", require_json=True)
        self.assertEqual(invalid_json["counts"]["json_errors"], 1)
        mismatch = self.one(
            "/ok", json_expectations=(LOAD.JsonExpectation("/nested/value", 4),))
        self.assertEqual(mismatch["counts"]["json_errors"], 1)
        too_large = self.one("/large", max_response_bytes=16)
        self.assertEqual(too_large["counts"]["response_too_large_errors"], 1)

        unused = socket.socket()
        unused.bind(("127.0.0.1", 0))
        port = unused.getsockname()[1]
        unused.close()
        transport = LOAD.run_load(LOAD.LoadConfig(
            url=f"http://127.0.0.1:{port}/", rate=10, duration=0.1,
            workers=1, queue_capacity=1, timeout=0.2))
        self.assertEqual(transport["counts"]["transport_errors"], 1)
        self.assertEqual(transport["statuses"], {})

    def test_open_loop_offers_continue_while_slow_work_is_dropped(self):
        report = LOAD.run_load(LOAD.LoadConfig(
            url=self.base + "/slow", rate=100, duration=0.2,
            workers=1, queue_capacity=1, timeout=1,
            json_expectations=(LOAD.JsonExpectation("/status", "slow"),)))
        counts = report["counts"]
        self.assertEqual(counts["offered"], 20)
        self.assertGreater(counts["dropped"], 0)
        self.assertEqual(counts["accepted"] + counts["dropped"], counts["offered"])
        self.assertEqual(counts["completed"], counts["accepted"])
        self.assertEqual(counts["errors"], 0)
        self.assertLess(report["timing"]["offering_elapsed_seconds"], 0.35)
        self.assertGreater(report["timing"]["total_elapsed_seconds"], 0.25)

    def test_total_sample_budget_is_checked_before_starting_workers(self):
        before = {child.pid for child in multiprocessing.active_children()
                  if child.name.startswith("stiff-load-")}
        with self.assertRaisesRegex(LOAD.ConfigurationError, "at most 1000000"):
            LOAD.run_load(LOAD.LoadConfig(
                url=self.base + "/", rate=100_000, duration=10.01))
        after = {child.pid for child in multiprocessing.active_children()
                 if child.name.startswith("stiff-load-")}
        self.assertEqual(after, before)
        checked = LOAD.validate_config(LOAD.LoadConfig(
            url=self.base + "/", rate=100_000, duration=10))
        self.assertEqual(checked.rate * checked.duration, 1_000_000)

    def test_whole_transfer_timeout_stops_trickle_worker_before_return(self):
        before = {child.pid for child in multiprocessing.active_children()
                  if child.name.startswith("stiff-load-")}
        started = time.monotonic()
        report = self.one("/trickle", workers=1, timeout=0.12, drain_timeout=1)
        elapsed = time.monotonic() - started
        self.assertLess(elapsed, 0.8)
        self.assertEqual(report["counts"]["timeout_errors"], 1)
        self.assertEqual(report["counts"]["completed"], 1)
        after = {child.pid for child in multiprocessing.active_children()
                 if child.name.startswith("stiff-load-")}
        self.assertEqual(after, before)

    def test_global_drain_deadline_cancels_active_and_queued_work(self):
        started = time.monotonic()
        report = LOAD.run_load(LOAD.LoadConfig(
            url=self.base + "/trickle", rate=100, duration=0.1,
            workers=1, queue_capacity=10, timeout=2, drain_timeout=0.15))
        elapsed = time.monotonic() - started
        self.assertLess(elapsed, 0.7)
        counts = report["counts"]
        self.assertEqual(counts["accepted"], counts["completed"])
        self.assertGreater(counts["drain_timeout_errors"], 0)
        self.assertFalse(any(child.name.startswith("stiff-load-")
                             for child in multiprocessing.active_children()))


if __name__ == "__main__":
    unittest.main()
