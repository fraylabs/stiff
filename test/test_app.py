"""Application-layer journeys through compiled native executables."""
import concurrent.futures
import socket
import http.client
import json
from pathlib import Path
import queue
import signal
import subprocess
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parent.parent


class AppTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="stiff-app-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.directory = Path(cls.temporary.name)
        for source, name in (("examples/app.bend", "app"), ("test/fixtures/app-policy.bend", "policy"),
                             ("test/fixtures/observed-server.bend", "observed")):
            result = subprocess.run([str(ROOT / "scripts/build-native.sh"), source, str(cls.directory / name)],
                                    cwd=ROOT, capture_output=True, text=True, timeout=120)
            if result.returncode:
                raise RuntimeError(result.stdout + result.stderr)
            (cls.directory / (name + ".c")).unlink()

    def setUp(self):
        self.lines = queue.Queue()
        self.logs = queue.Queue()
        self.diagnostics = []
        self.server = subprocess.Popen([str(self.directory / getattr(self, "binary", "app")), "127.0.0.1", "0"],
                                       cwd=self.directory, env={"PATH": "/nonexistent"},
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(self.cleanup_server)
        def read():
            for line in self.server.stdout:
                self.lines.put(line.strip())
        threading.Thread(target=read, daemon=True).start()
        def read_logs():
            for line in self.server.stderr:
                self.diagnostics.append(line)
                self.logs.put(line)
        self.log_reader = threading.Thread(target=read_logs, daemon=True)
        self.log_reader.start()
        line = self.lines.get(timeout=5)
        self.assertTrue(line.startswith("LISTENING "), line)
        self.port = int(line.split()[1])

    def cleanup_server(self):
        if self.server.poll() is None:
            self.server.send_signal(signal.SIGTERM)
        try:
            self.server.wait(timeout=4)
        except subprocess.TimeoutExpired:
            self.server.kill()
            self.server.wait()
        self.log_reader.join(timeout=1)
        diagnostics = "".join(self.diagnostics)
        self.server.stdout.close()
        self.server.stderr.close()
        self.assertEqual(self.server.returncode, 0, diagnostics)
        self.assertFalse(self.log_reader.is_alive())
        for line in self.diagnostics:
            record = json.loads(line)
            self.assertEqual(record["event"], "handler_result")
            self.assertEqual(set(record), {"event", "request_id", "method", "proposed_status", "active", "duration_ms"})

    def request(self, method="GET", path="/health", body=None, authorized=True, extra_headers=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=3)
        headers = {"Content-Type": "application/json"}
        if authorized:
            headers["X-Demo-Access"] = "allowed"
        headers.update(extra_headers or {})
        try:
            connection.request(method, path, body=body, headers=headers)
            response = connection.getresponse()
            return response.status, {k.lower(): v for k, v in response.getheaders()}, response.read()
        finally:
            connection.close()

    def test_valid_application_journey_and_unicode(self):
        status, headers, body = self.request()
        self.assertEqual((status, json.loads(body)), (200, {"status": "ok"}))
        self.assertEqual(headers["x-stiff"], "app")
        for name in ('Brian', '🌱' * 40, 'quote" and newline\n'):
            status, headers, body = self.request("POST", "/greet?ignored=yes", json.dumps({"name": name}))
            self.assertEqual((status, json.loads(body)), (200, {"greeting": "Hello, " + name}))
            self.assertEqual(headers["content-type"], "application/json")
            self.assertEqual(self.lines.get(timeout=1), "GREETING")

    def test_exact_routes_and_wrong_method(self):
        for path in ("/absent", "/Health", "/health/", "/%68ealth"):
            status, headers, body = self.request(path=path)
            self.assertEqual(status, 404)
            self.assertEqual(json.loads(body)["error"]["code"], "not_found")
            self.assertEqual(headers["x-stiff"], "app")
        for method in ("POST", "HEAD", "OPTIONS"):
            status, headers, body = self.request(method, "/health")
            self.assertEqual(status, 405)
            self.assertEqual(headers["allow"], "GET")
            if method != "HEAD":
                self.assertEqual(json.loads(body)["error"]["code"], "method_not_allowed")
        self.assertEqual(self.request("GET", "/greet")[1]["allow"], "POST")

    def test_middleware_short_circuits_before_routing_and_parsing(self):
        for path in ("/greet", "/absent"):
            status, headers, body = self.request("POST", path, "private-invalid-json", authorized=False)
            self.assertEqual(status, 403)
            self.assertEqual(headers["x-stiff"], "app")
            self.assertEqual(json.loads(body)["error"]["code"], "access_denied")
            self.assertNotIn(b"private", body)
        self.assertTrue(self.lines.empty())

    def test_json_and_field_validation_precede_handler_effect(self):
        status, headers, body = self.request("POST", "/greet", "private-invalid-json")
        self.assertEqual(status, 400)
        self.assertEqual(json.loads(body)["error"]["code"], "invalid_json")
        self.assertNotIn(b"private", body)
        cases = [({}, "required"), ({"name": None}, "type"), ({"name": 1}, "type"),
                 ({"name": ""}, "length"), ({"name": "x" * 41}, "length"),
                 ({"name": "🌱" * 41}, "length"), ([], "object_required"), (None, "object_required")]
        for value, reason in cases:
            with self.subTest(value=value):
                status, headers, body = self.request("POST", "/greet", json.dumps(value))
                self.assertEqual(status, 422)
                self.assertEqual(json.loads(body), {"error": {"code": "validation_failed",
                    "message": "Request validation failed", "field": "name", "reason": reason}})
                self.assertEqual(headers["x-stiff"], "app")
        self.assertTrue(self.lines.empty())
        self.assertEqual(self.request()[0], 200)

    def test_route_precedence_and_unique_allow_methods(self):
        result = subprocess.run([str(self.directory / "policy")], cwd=self.directory,
                                env={"PATH": "/nonexistent"}, capture_output=True, text=True, timeout=3)
        self.assertEqual((result.returncode, result.stdout, result.stderr),
                         (0, "first\nGET, POST\nmissing\nsecond\n", ""))


class ObservabilityTests(unittest.TestCase):
    binary = "observed"
    setUpClass = classmethod(AppTests.setUpClass.__func__)
    setUp = AppTests.setUp
    cleanup_server = AppTests.cleanup_server
    request = AppTests.request

    def test_generated_ids_structured_logs_and_private_values(self):
        ids = []
        cases = [("GET", "/health?secret=query-private", None, 200),
                 ("POST", "/greet", "body-private", 400),
                 ("GET", "/path-private", None, 404)]
        for method, path, body, expected in cases:
            status, headers, response = self.request(method, path, body,
                extra_headers={"X-Request-Id": "forged-private", "Authorization": "Bearer token-private"})
            self.assertEqual(status, expected)
            record = json.loads(self.logs.get(timeout=1))
            self.assertEqual(record["request_id"], headers["x-request-id"])
            self.assertTrue(record["request_id"].isdigit())
            self.assertEqual(record["proposed_status"], status)
            self.assertEqual(record["method"], method)
            self.assertTrue(record["active"])
            self.assertGreaterEqual(record["duration_ms"], 0)
            self.assertNotIn("private", json.dumps(record))
            ids.append(record["request_id"])
        self.assertEqual(len(set(ids)), 3)
        status, _, body = self.request(path="/metrics")
        self.assertEqual(status, 200)
        snapshot = json.loads(body)
        self.assertEqual(snapshot["admitted"], 4)
        self.assertLessEqual(snapshot["completed"], 3)
        self.assertLessEqual(snapshot["failed"], 2)
        for field in ("rejected", "expired", "read_expired", "disconnected"):
            self.assertEqual(snapshot[field], 0)
        self.assertGreaterEqual(snapshot["pending"], 1)
        self.assertGreaterEqual(snapshot["handlers"], 1)
        self.assertGreaterEqual(snapshot["connections"], 1)
        # Compare exact totals only after the event thread has drained/closed.
        self.server.send_signal(signal.SIGTERM)
        final = json.loads(self.lines.get(timeout=2))
        self.server.wait(timeout=2)
        self.assertEqual(final["admitted"], 4)
        self.assertEqual(final["completed"], 4)
        self.assertEqual(final["failed"], 2)
        for field in ("connections", "pending", "handlers"):
            self.assertEqual(final[field], 0)


    def test_overload_deadlines_late_logs_and_final_gauges(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
            pending = [pool.submit(self.request, "GET", "/slow") for _ in range(3)]
            for _ in pending:
                self.assertEqual(self.lines.get(timeout=1), "SLOW")
            status, headers, _ = self.request()
            self.assertEqual(status, 503)
            self.assertNotIn("x-request-id", headers)
            for result in pending:
                with self.assertRaises((http.client.RemoteDisconnected, ConnectionResetError)):
                    result.result(timeout=1)
            for _ in pending:
                record = json.loads(self.logs.get(timeout=1))
                self.assertFalse(record["active"])
                self.assertEqual(record["proposed_status"], 200)
                self.assertGreaterEqual(record["duration_ms"], 500)
        self.server.send_signal(signal.SIGTERM)
        final = json.loads(self.lines.get(timeout=2))
        self.server.wait(timeout=2)
        self.assertEqual(final["admitted"], 3)
        self.assertEqual(final["expired"], 3)
        self.assertEqual(final["rejected"], 1)
        self.assertEqual(final["completed"], 0)
        self.assertEqual(final["failed"], 0)
        for field in ("connections", "pending", "handlers"):
            self.assertEqual(final[field], 0)

    def test_incomplete_connection_timeout_has_no_handler_log(self):
        with socket.create_connection(("127.0.0.1", self.port), timeout=2) as peer:
            peer.sendall(b"GET /health HTTP/1.1\r\nX-Secret: private")
            while peer.recv(4096):
                pass
        self.assertTrue(self.logs.empty())
        status, _, body = self.request(path="/metrics")
        self.assertEqual(status, 200)
        snapshot = json.loads(body)
        self.assertEqual(snapshot["read_expired"], 1)
        self.assertEqual(snapshot["admitted"], 1)
        self.assertEqual(snapshot["expired"], 0)
