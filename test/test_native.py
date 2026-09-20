"""Native integration and proof checks. Python stdlib only; no hosted JS runtime."""
import gzip
import http.server
import json
import os
from pathlib import Path
import shutil
import signal
import ssl
import subprocess
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parent.parent
BEND = os.environ.get("BEND", str(ROOT / ".cache/toolchain/bin/bend"))


class NativeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="stiff-native-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.directory = Path(cls.temporary.name)
        cls.stop = threading.Event()
        cls.interrupted = threading.Event()
        cls.visits = {}
        cls.lock = threading.Lock()
        for source, name in [("examples/get-json.bend", "get-json"),
                             ("test/fixtures/native-http.bend", "http"),
                             ("test/fixtures/native-json.bend", "json"),
                             ("test/fixtures/native-policy.bend", "policy")]:
            result = subprocess.run([str(ROOT / "scripts/build-native.sh"), source,
                                     str(ROOT / ".cache/native" / name)], cwd=ROOT,
                                    capture_output=True, text=True, timeout=60)
            if result.returncode:
                raise RuntimeError(result.stdout + result.stderr)
            shutil.copy2(ROOT / ".cache/native" / name, cls.directory / name)
        cls.cert = cls.directory / "cert.pem"
        key = cls.directory / "key.pem"
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                        "-keyout", str(key), "-out", str(cls.cert), "-days", "1",
                        "-subj", "/CN=localhost", "-addext", "subjectAltName=IP:127.0.0.1"],
                       check=True, capture_output=True, timeout=30)

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *_args):
                pass

            def do_GET(self):
                with cls.lock:
                    cls.visits[self.path] = cls.visits.get(self.path, 0) + 1
                if self.path in ("/slow", "/slow-body", "/interrupt"):
                    if self.path == "/slow-body":
                        self.send_response(200)
                        self.send_header("Content-Length", "100")
                        self.end_headers()
                        self.wfile.write(b"{")
                        self.wfile.flush()
                    if self.path == "/interrupt":
                        cls.interrupted.set()
                    cls.stop.wait(15)
                    return
                status = 503 if self.path == "/status" else 200
                body = b'{"slideshow":{"title":"Native Bend"}}'
                headers = {}
                if self.path == "/redirect":
                    status, body = 302, b"{}"
                    headers["Location"] = "/destination"
                elif self.path == "/empty":
                    status, body = 204, b""
                elif self.path == "/bad-json":
                    body = b"{"
                elif self.path == "/bad-utf8":
                    body = bytes([0xf0, 0x28, 0x8c, 0xbc])
                elif self.path == "/large":
                    body = b"x" * 2048
                elif self.path == "/gzip":
                    body = gzip.compress(b"x" * 2048)
                    headers["Content-Encoding"] = "gzip"
                elif self.path == "/unicode":
                    body = "🌱".encode()
                elif self.path == "/bom":
                    body = b"\xef\xbb\xbf{}"
                elif self.path == "/post":
                    if self.headers.get("Content-Type") != "application/json":
                        status, body = 400, b"wrong content type"
                    else:
                        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
                self.send_response(status)
                for name, value in headers.items():
                    self.send_header(name, value)
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Connection", "close")
                self.end_headers()
                try:
                    self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError):
                    pass

            do_POST = do_GET

        cls.servers = []
        for secure in (False, True):
            server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            server.daemon_threads = True
            if secure:
                context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
                context.load_cert_chain(cls.cert, key)
                server.socket = context.wrap_socket(server.socket, server_side=True)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            cls.servers.append(server)
        cls.base = f"http://127.0.0.1:{cls.servers[0].server_port}"
        cls.tls_url = f"https://127.0.0.1:{cls.servers[1].server_port}"
        cls.addClassCleanup(cls.close_servers)

    @classmethod
    def close_servers(cls):
        cls.stop.set()
        for server in cls.servers:
            server.shutdown()
            server.server_close()

    def setUp(self):
        with self.lock:
            self.visits.clear()
        self.interrupted.clear()

    def environment(self, trust=True):
        env = {"PATH": "/nonexistent", "NO_PROXY": "*"}
        if trust:
            env["STIFF_CA_BUNDLE"] = str(self.cert)
        return env

    def execute(self, name, *args, trust=True):
        return subprocess.run([str(self.directory / name), *args], cwd=self.directory,
                              env=self.environment(trust), capture_output=True, text=True,
                              encoding="utf-8", timeout=5)

    def http(self, route, method="GET", body="", timeout="2000", limit="1048576"):
        url = self.base + route if route.startswith("/") else route
        return self.execute("http", url, method, body, timeout, limit)

    def test_https_without_runtime_or_source_on_path(self):
        result = self.execute("get-json", self.tls_url)
        self.assertEqual((result.returncode, result.stdout, result.stderr),
                         (0, "HTTP 200\nNative Bend\n", ""))

    def test_untrusted_certificate(self):
        result = self.execute("get-json", self.tls_url, trust=False)
        self.assertEqual(result.returncode, 1)
        self.assertTrue(result.stderr.startswith("network:"), result.stderr)

    def test_http_status_without_retry(self):
        self.assertTrue(self.http("/status").stdout.startswith("503:"))
        self.assertEqual(self.visits.get("/status"), 1)

    def test_redirect_is_not_followed(self):
        self.assertEqual(self.http("/redirect").stdout, "302:{}\n")
        self.assertNotIn("/destination", self.visits)

    def test_json_post_once(self):
        self.assertEqual(self.http("/post", "POST", "[1,2,3]").stdout, "200:[1,2,3]\n")
        self.assertEqual(self.visits.get("/post"), 1)

    def test_invalid_requests_before_sending(self):
        for url in ("file:///tmp/anything", "ftp://example.com", "http://user:pass@127.0.0.1"):
            with self.subTest(url=url):
                self.assertEqual(self.http(url).stderr, "invalid_request\n")
        self.assertEqual(self.http("/invalid", body="body").stderr, "invalid_request\n")
        self.assertEqual(self.http("/invalid", timeout="0").stderr, "invalid_request\n")
        self.assertEqual(self.http("/invalid", limit="0").stderr, "invalid_request\n")
        for body in ("{", "NaN", "{} garbage", "/*comment*/{}"):
            with self.subTest(body=body):
                self.assertEqual(self.http("/invalid", "POST", body).stderr, "invalid_json_request\n")
        self.assertNotIn("/invalid", self.visits)

    def test_deadline_covers_headers_and_body(self):
        for route in ("/slow", "/slow-body"):
            with self.subTest(route=route):
                self.assertEqual(self.http(route, timeout="80").stderr, "timeout\n")

    def test_decompressed_body_limit(self):
        for route in ("/large", "/gzip"):
            with self.subTest(route=route):
                self.assertEqual(self.http(route, limit="10").stderr, "body_too_large\n")

    def test_utf8_and_bom(self):
        self.assertEqual(self.http("/unicode").stdout, "200:🌱\n")
        self.assertEqual(self.http("/bad-utf8").stderr, "invalid_utf8\n")
        self.assertEqual(self.http("/bom").stdout, "200:{}\n")

    def test_empty_body_and_malformed_json(self):
        self.assertEqual(self.http("/empty").stdout, "204:\n")
        result = self.execute("get-json", self.base + "/bad-json")
        self.assertEqual(result.returncode, 1)
        self.assertTrue(result.stderr.startswith("invalid_json_response:"), result.stderr)

    def test_json_native_layout(self):
        for value, expected in ((True, "true"), (False, "false"), (None, "null"),
                                (1.25, "1.25"), ("🌱", "🌱"), ("\0", "\0"),
                                ([1, True, None], "array"), ({"nested": True}, "object")):
            with self.subTest(value=value):
                result = self.execute("json", json.dumps({"key": value}))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, f"object:{expected}\n")
        self.assertEqual(self.execute("json", "null").stdout, "null:missing\n")
        self.assertEqual(self.execute("json", '"\\ud83c\\udf31"').stdout, "🌱:missing\n")
        self.assertEqual(self.execute("json", '{"key":1,"key":2}').stdout, "object:2\n")

    def test_json_rejections(self):
        for value in ("{", "{} {}", "/*x*/{}", "[1,]", "01", '{"key\\u0000suffix":1}',
                      '"\\ud800"', '"\\udc00"'):
            with self.subTest(value=value):
                self.assertEqual(self.execute("json", value).stderr, "invalid_json_response\n")
        for value in ("1e999", "9007199254740993"):
            with self.subTest(value=value):
                self.assertEqual(self.execute("json", value).stderr, "json_number_range\n")
        self.assertEqual(self.execute("json", "[" * 140 + "0" + "]" * 140).stderr, "json_too_deep\n")

    def test_interrupt_without_replay_or_continuation(self):
        with subprocess.Popen([str(self.directory / "http"), self.base + "/interrupt", "GET", "", "10000", "1048576"],
                              cwd=self.directory, env=self.environment(), stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, text=True) as child:
            try:
                self.assertTrue(self.interrupted.wait(5), "Request never arrived")
                child.send_signal(signal.SIGINT)
                out, _err = child.communicate(timeout=5)
                self.assertEqual(child.returncode, -signal.SIGINT)
                self.assertEqual(out, "")
                self.assertEqual(self.visits.get("/interrupt"), 1)
            finally:
                if child.poll() is None:
                    child.kill()
                    child.wait()

    def test_pure_policy_boundaries_and_defaults(self):
        result = self.execute("policy")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "false:true:true:false:false\n10000:1048576\n")

    def test_pure_laws_check_without_foreign_dependencies(self):
        result = subprocess.run([BEND, "src/PROOF.bend", "--check-only"], cwd=ROOT,
                                capture_output=True, text=True, timeout=15,
                                env={**os.environ, "BEND_NO_TELEMETRY": "1"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("All terms check", result.stdout)
        self.assertNotIn("unsafe", result.stdout + result.stderr)

    def test_false_proof_is_rejected(self):
        with tempfile.TemporaryDirectory(prefix="proof-", dir=ROOT / ".cache") as directory:
            file = Path(directory) / "bad.bend"
            file.write_text('import Base\nimport ../../src/http.bend as Http\n'
                            'def false_claim() -> {Http.timeout(Http.get("https://example.com")) == 1 : U32}:\n  {==}\n')
            result = subprocess.run([BEND, str(file), "--check-only"], cwd=ROOT,
                                    capture_output=True, text=True, timeout=15,
                                    env={**os.environ, "BEND_NO_TELEMETRY": "1"})
            self.assertNotEqual(result.returncode, 0)
            output = result.stdout + result.stderr
            self.assertRegex(output, r"expected\s*:\s*10000")
            self.assertRegex(output, r"observed\s*:\s*1\b")


if __name__ == "__main__":
    unittest.main()
