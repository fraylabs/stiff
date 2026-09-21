"""Real native server/client tests using loopback and synthetic requests only."""
import concurrent.futures
import http.client
import json
import os
from pathlib import Path
import queue
import shutil
import signal
import socket
import subprocess
import struct
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parent.parent


class ServerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="stiff-server-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.directory = Path(cls.temporary.name)
        for source, name in [("test/fixtures/native-server.bend", "server"),
                             ("examples/server.bend", "example"),
                             ("test/fixtures/native-http.bend", "client")]:
            result = subprocess.run([str(ROOT / "scripts/build-native.sh"), source,
                                     str(cls.directory / name)], cwd=ROOT,
                                    capture_output=True, text=True, timeout=120)
            if result.returncode:
                raise RuntimeError(result.stdout + result.stderr)
            (cls.directory / (name + ".c")).unlink()

    def setUp(self):
        self.lines = queue.Queue()
        self.server = subprocess.Popen([str(self.directory / "server")], cwd=self.directory,
                                       env={"PATH": "/nonexistent"}, stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, text=True)
        self.addCleanup(self.cleanup_server)
        def read():
            for line in self.server.stdout:
                self.lines.put(line.rstrip())
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
        for marker in ("ERROR: AddressSanitizer", "ERROR: LeakSanitizer", "runtime error:"):
            self.assertNotIn(marker, diagnostics)

    def request(self, method="GET", path="/health", body=None, headers=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=4)
        try:
            connection.request(method, path, body=body, headers=headers or {})
            result = connection.getresponse()
            return result.status, dict(result.getheaders()), result.read()
        finally:
            connection.close()

    def raw(self, request):
        with socket.create_connection(("127.0.0.1", self.port), timeout=4) as peer:
            peer.sendall(request)
            chunks = []
            while True:
                try:
                    chunk = peer.recv(65536)
                except ConnectionResetError:
                    break
                if not chunk:
                    break
                chunks.append(chunk)
            return b"".join(chunks)

    def handling(self, count=1):
        for _ in range(count):
            self.assertTrue(self.lines.get(timeout=3).startswith("HANDLING "))

    def test_native_stiff_client_to_server(self):
        result = subprocess.run([str(self.directory / "client"),
                                 f"http://127.0.0.1:{self.port}/echo", "POST", '{"native":true}',
                                 "2000", "1024"], cwd=self.directory,
                                env={"PATH": "/nonexistent", "NO_PROXY": "*"},
                                capture_output=True, text=True, timeout=4)
        self.assertEqual((result.returncode, result.stdout, result.stderr),
                         (0, '200:{"native":true}\n', ""))

    def test_routes_query_headers_and_json(self):
        status, headers, body = self.request(path="/health?probe=1")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body), {"message": "healthy"})
        headers = {k.lower(): v for k, v in headers.items()}
        self.assertEqual(headers["x-stiff"], "native")
        self.assertEqual(headers["content-type"], "application/json")
        self.assertEqual(headers["connection"], "close")
        self.assertEqual(self.request(path="/header", headers={"X-TeSt": "synthetic"})[2], b"synthetic")
        self.assertEqual(self.request("GET", "/echo")[0], 404)
        self.assertEqual(self.request("POST", "/echo", "{")[0], 400)
        self.assertEqual(self.request(path="/missing")[0], 404)

    def test_api_constructs_json_response_from_parsed_input(self):
        value = {"text": 'quotes" backslash\\ newline\n nul\0 🌱', "items": [None, True, 1.25]}
        status, headers, body = self.request("POST", "/inspect", json.dumps(value))
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body), {"received": value, "accepted": True, "labels": ["native", "Bend"]})
        self.assertEqual(self.request("POST", "/inspect", "{")[0], 400)
        status, headers, body = self.request(path="/encode-failure")
        self.assertEqual(status, 500)
        self.assertEqual(json.loads(body), {"error": "JSON encoding failed"})
        self.assertNotIn(b"private-value", body)

    def test_bounded_bodies_and_utf8(self):
        self.assertEqual(self.request("POST", "/echo", b"x" * 1025)[0], 413)
        self.assertEqual(self.request("POST", "/echo", b"\xff")[0], 400)
        result = self.raw(b"POST /echo HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n"
                          + b"401\r\n" + b"x" * 1025 + b"\r\n0\r\n\r\n")
        self.assertIn(b" 413 ", result.split(b"\r\n", 1)[0])
        self.assertEqual(self.request()[0], 200)

    def test_malformed_framing_and_header_limit(self):
        for headers in (b"Content-Length: 1\r\nContent-Length: 2\r\n",
                        b"Content-Length: -1\r\n",
                        b"X-Huge: " + b"x" * 17000 + b"\r\n"):
            with self.subTest(headers=headers[:50]):
                response = self.raw(b"POST /echo HTTP/1.1\r\nHost: localhost\r\n" + headers + b"\r\n{}")
                self.assertNotIn(b" 200 ", response.split(b"\r\n", 1)[0])
        self.assertEqual(self.request()[0], 200)

    def test_ambiguous_transfer_framing_is_rejected(self):
        response = self.raw(b"POST /echo HTTP/1.1\r\nHost: localhost\r\n"
                            b"Transfer-Encoding: chunked\r\nContent-Length: 2\r\n\r\n"
                            b"2\r\n{}\r\n0\r\n\r\n")
        self.assertIn(b" 400 ", response.split(b"\r\n", 1)[0])
        self.assertEqual(self.request()[0], 200)

    def test_concurrent_handlers_and_overload(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            pending = [pool.submit(self.request, "GET", "/slow") for _ in range(4)]
            self.handling(4)
            self.assertEqual(self.request()[0], 503)
            self.assertEqual([f.result()[0] for f in pending], [200] * 4)
        self.assertEqual(self.request()[0], 200)

    def test_slow_handler_does_not_block_fast_request(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
            slow = pool.submit(self.request, "GET", "/slow")
            self.handling()
            self.assertEqual(self.request()[0], 200)
            self.assertFalse(slow.done(), "Fast route waited for slow handler")
            self.assertEqual(slow.result()[0], 200)

    def test_graceful_signal_drains_dispatched_request(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
            slow = pool.submit(self.request, "GET", "/slow")
            self.handling()
            self.server.send_signal(signal.SIGTERM)
            self.assertEqual(slow.result()[0], 200)
        self.server.wait(timeout=3)
        self.assertEqual(self.server.returncode, 0)
        self.assertEqual(self.lines.get(timeout=2), "STOPPED")

    def test_sigint_and_idle_connection_shutdown(self):
        with socket.create_connection(("127.0.0.1", self.port), timeout=3) as peer:
            peer.sendall(b"GET /health HTTP/1.1\r\nHost:")
            self.server.send_signal(signal.SIGINT)
            self.server.wait(timeout=3)
            self.assertEqual(self.server.returncode, 0)

    def test_disconnected_clients_do_not_crash_server(self):
        for _ in range(12):
            with socket.create_connection(("127.0.0.1", self.port), timeout=3) as peer:
                peer.sendall(b"GET /slow HTTP/1.1\r\nHost: localhost\r\n\r\n")
                self.handling()
                peer.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
            time.sleep(0.3)
        time.sleep(0.3)
        self.assertEqual(self.request()[0], 200)
        self.assertIsNone(self.server.poll())

    def test_invalid_response_becomes_500_and_205_has_no_body(self):
        for path in ("/bad-response", "/bad-status"):
            status, headers, body = self.request(path=path)
            self.assertEqual(status, 500)
            self.assertNotIn("injected", {k.lower() for k in headers})
            self.assertNotIn(b"secret", body)
        status, headers, body = self.request(path="/no-content")
        self.assertEqual((status, body), (205, b""))

    def test_handler_deadline_releases_request(self):
        with self.assertRaises((http.client.RemoteDisconnected, ConnectionResetError)):
            self.request(path="/hung")
        self.assertEqual(self.request()[0], 200)

    def test_grace_deadline_closes_unfinished_request(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
            pending = pool.submit(self.request, "GET", "/hung")
            self.handling()
            self.server.send_signal(signal.SIGTERM)
            with self.assertRaises((http.client.RemoteDisconnected, ConnectionResetError)):
                pending.result(timeout=1.5)
        # Bend computations finish independently; grace bounds network draining.
        self.server.wait(timeout=3)
        self.assertEqual(self.server.returncode, 0)

    def test_programmatic_stop_drains_its_own_reply(self):
        self.assertEqual(self.request(path="/stop")[0], 200)
        self.server.wait(timeout=3)
        self.assertEqual(self.server.returncode, 0)

    def test_configurable_address_and_invalid_config(self):
        for address, port in (("invalid", "0"), ("127.0.0.1", "70000")):
            result = subprocess.run([str(self.directory / "example"), address, port],
                                    capture_output=True, text=True, timeout=4)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(result.stderr, "invalid_config\n")


if __name__ == "__main__":
    unittest.main()
