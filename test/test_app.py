"""Application-layer journeys through compiled native executables."""
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
        for source, name in (("examples/app.bend", "app"), ("test/fixtures/app-policy.bend", "policy")):
            result = subprocess.run([str(ROOT / "scripts/build-native.sh"), source, str(cls.directory / name)],
                                    cwd=ROOT, capture_output=True, text=True, timeout=120)
            if result.returncode:
                raise RuntimeError(result.stdout + result.stderr)
            (cls.directory / (name + ".c")).unlink()

    def setUp(self):
        self.lines = queue.Queue()
        self.server = subprocess.Popen([str(self.directory / "app"), "127.0.0.1", "0"],
                                       cwd=self.directory, env={"PATH": "/nonexistent"},
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(self.cleanup_server)
        def read():
            for line in self.server.stdout:
                self.lines.put(line.strip())
        threading.Thread(target=read, daemon=True).start()
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
        diagnostics = self.server.stderr.read()
        self.server.stdout.close()
        self.server.stderr.close()
        self.assertEqual(self.server.returncode, 0, diagnostics)
        self.assertEqual(diagnostics, "")

    def request(self, method="GET", path="/health", body=None, authorized=True):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=3)
        headers = {"Content-Type": "application/json"}
        if authorized:
            headers["X-Demo-Access"] = "allowed"
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
