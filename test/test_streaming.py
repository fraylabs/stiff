"""Native bounded response streaming, SSE and keep-alive tests."""
import http.client
import json
from pathlib import Path
import select
import signal
import socket
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parent.parent


class StreamingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="stiff-streaming-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.directory = Path(cls.temporary.name)
        result = subprocess.run(
            [str(ROOT / "scripts/build-native.sh"), "test/fixtures/stream-server.bend",
             str(cls.directory / "server")],
            cwd=ROOT, capture_output=True, text=True, timeout=120)
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr)
        (cls.directory / "server.c").unlink()

    def setUp(self):
        self.server = subprocess.Popen(
            [str(self.directory / "server")], cwd=self.directory,
            env={"PATH": "/nonexistent"}, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True)
        self.addCleanup(self.cleanup_server)
        line = self.server.stdout.readline().strip()
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

    def raw_request(self, request):
        with socket.create_connection(("127.0.0.1", self.port), timeout=2) as peer:
            peer.sendall(request)
            response = b""
            while chunk := peer.recv(4096):
                response += chunk
        head, body = response.split(b"\r\n\r\n", 1)
        lines = head.split(b"\r\n")
        status = int(lines[0].split(b" ", 2)[1])
        headers = {}
        for line in lines[1:]:
            name, value = line.split(b":", 1)
            headers[name.lower()] = value.strip().lower()
        return status, headers, body

    def assert_transport_error(self, response, status, code, message,
                               content_type=b"application/json"):
        actual_status, headers, body = response
        self.assertEqual(actual_status, status)
        self.assertEqual(headers[b"content-type"], content_type)
        self.assertEqual(headers[b"connection"], b"close")
        self.assertEqual(int(headers[b"content-length"]), len(body))
        self.assertEqual(json.loads(body), {"error": {"code": code, "message": message}})

    def test_chunks_arrive_before_handler_finishes(self):
        with socket.create_connection(("127.0.0.1", self.port), timeout=2) as peer:
            peer.sendall(b"GET /stream-close HTTP/1.1\r\nHost: localhost\r\n\r\n")
            received = b""
            while b"5\r\nalpha\r\n" not in received:
                received += peer.recv(4096)
            self.assertIn(b"Transfer-Encoding: chunked", received)
            self.assertIn(b"Connection: close", received)
            self.assertNotIn(b"beta", received)
            peer.settimeout(0.12)
            with self.assertRaises(socket.timeout):
                peer.recv(4096)
            peer.settimeout(2)
            while chunk := peer.recv(4096):
                received += chunk
        self.assertIn(b"4\r\nbeta\r\n0\r\n\r\n", received)

    def test_sse_frames_and_reuses_one_http_connection(self):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=3)
        try:
            connection.request("GET", "/events")
            response = connection.getresponse()
            self.assertEqual(response.status, 200)
            headers = {name.lower(): value.lower() for name, value in response.getheaders()}
            self.assertEqual(headers["content-type"], "text/event-stream")
            self.assertEqual(headers["cache-control"], "no-cache")
            self.assertEqual(headers["connection"], "keep-alive")
            self.assertEqual(response.read(), b"event: ready\ndata: one\n\ndata: two\n\n")
            first_socket = connection.sock
            self.assertIsNotNone(first_socket)

            self.assertIs(connection.sock, first_socket)
            connection.request("GET", "/health")
            self.assertIs(connection.sock, first_socket)
            second = connection.getresponse()
            self.assertEqual((second.status, second.read()), (200, b'{"ok":true}'))
            self.assertEqual(dict(second.getheaders())["Connection"], "close")
        finally:
            connection.close()

    def test_keep_alive_rearms_absolute_read_deadline(self):
        with socket.create_connection(("127.0.0.1", self.port), timeout=2) as peer:
            peer.sendall(b"GET /events HTTP/1.1\r\nHost: localhost\r\n\r\n")
            response = b""
            while not response.endswith(b"0\r\n\r\n"):
                response += peer.recv(4096)
            self.assertIn(b"Connection: keep-alive", response)
            peer.settimeout(1.5)
            try:
                self.assertEqual(peer.recv(4096), b"")
            except ConnectionResetError:
                pass

    def test_ordinary_reply_keeps_close_default(self):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=3)
        try:
            connection.request("GET", "/health")
            response = connection.getresponse()
            self.assertEqual((response.status, response.read()), (200, b'{"ok":true}'))
            self.assertEqual(dict(response.getheaders())["Connection"], "close")
            self.assertIsNone(connection.sock)
        finally:
            connection.close()

    def test_empty_stream_chunk_does_not_wait_for_write_callback(self):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=3)
        try:
            connection.request("GET", "/empty")
            response = connection.getresponse()
            self.assertEqual((response.status, response.read()), (200, b"ok"))
        finally:
            connection.close()

    def test_concurrent_stream_write_is_rejected_without_stranding_first(self):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=6)
        try:
            connection.request("GET", "/concurrent")
            response = connection.getresponse()
            ready, _, _ = select.select([self.server.stdout], [], [], 2)
            self.assertTrue(ready, "overlapping write did not return")
            self.assertEqual(self.server.stdout.readline().strip(),
                             "PENDING response_write_pending")
            self.assertEqual(response.status, 200)
            self.assertEqual(len(response.read()), 4 * 1024 * 1024)
        finally:
            connection.close()

    def test_reset_wakes_pending_chunk_writer_and_releases_handler(self):
        for iteration in range(6):
            peer = socket.create_connection(("127.0.0.1", self.port), timeout=3)
            peer.sendall(b"GET /write-reset HTTP/1.1\r\nHost: localhost\r\n\r\n")
            peer.settimeout(2)
            received = b""
            while b"\r\n\r\n" not in received:
                received += peer.recv(4096)
            peer.close()
            time.sleep(.1)

        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=3)
        try:
            connection.request("GET", "/health")
            response = connection.getresponse()
            self.assertEqual((response.status, response.read()), (200, b'{"ok":true}'))
        finally:
            connection.close()

    def test_aggregate_stream_body_is_bounded(self):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=8)
        try:
            connection.request("GET", "/limit")
            response = connection.getresponse()
            body = response.read()
            self.assertEqual(response.status, 200)
            self.assertEqual(len(body), 16 * 1024 * 1024)
            self.assertTrue(body.startswith(b"0123456789abcdef"))
            self.assertTrue(body.endswith(b"0123456789abcdef"))
        finally:
            connection.close()

    def test_transport_rejections_use_app_error_shape(self):
        invalid_utf8 = self.raw_request(
            b"POST /health HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1\r\n\r\n\xff")
        self.assert_transport_error(invalid_utf8, 400, "bad_request",
                                    "Request rejected by HTTP transport")

        ambiguous_framing = self.raw_request(
            b"POST /health HTTP/1.1\r\nHost: localhost\r\n"
            b"Content-Length: 4\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n")
        self.assert_transport_error(ambiguous_framing, 400, "bad_request",
                                    "Request rejected by HTTP transport")

    def test_head_transport_rejection_has_no_body(self):
        status, headers, body = self.raw_request(
            b"HEAD http://localhost/health HTTP/1.1\r\nHost: localhost\r\n\r\n")
        representation = json.dumps({"error": {
            "code": "bad_request", "message": "Request rejected by HTTP transport"
        }}, separators=(",", ":")).encode()
        self.assertEqual(status, 400)
        self.assertEqual(headers[b"content-type"], b"application/json")
        self.assertEqual(int(headers[b"content-length"]), len(representation))
        self.assertEqual(body, b"")

        status, headers, body = self.raw_request(
            b"HEAD /health HTTP/1.1\r\nHost: localhost\r\n"
            b"Content-Length: 4\r\nTransfer-Encoding: chunked\r\n\r\n")
        self.assertEqual(status, 400)
        self.assertEqual(headers[b"content-type"], b"application/json")
        self.assertEqual(int(headers[b"content-length"]), len(representation))
        self.assertEqual(body, b"")


class RequestStreamingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="stiff-request-streaming-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.directory = Path(cls.temporary.name)
        result = subprocess.run(
            [str(ROOT / "scripts/build-native.sh"), "test/fixtures/stream-request-server.bend",
             str(cls.directory / "server")],
            cwd=ROOT, capture_output=True, text=True, timeout=120)
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr)
        (cls.directory / "server.c").unlink()

    def setUp(self):
        self.server = subprocess.Popen(
            [str(self.directory / "server")], cwd=self.directory,
            env={"PATH": "/nonexistent"}, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True)
        self.addCleanup(self.cleanup_server)
        line = self.server.stdout.readline().strip()
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

    def next_marker(self, timeout=2):
        ready, _, _ = select.select([self.server.stdout], [], [], timeout)
        self.assertTrue(ready, "server did not deliver a body chunk incrementally")
        marker = self.server.stdout.readline().strip()
        self.assertTrue(marker.startswith("CHUNK "), marker)

    def receive(self, peer):
        response = b""
        while chunk := peer.recv(4096):
            response += chunk
        head, body = response.split(b"\r\n\r\n", 1)
        status = int(head.split(b" ", 2)[1])
        return status, head.lower(), body

    def recovery_request(self):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=3)
        try:
            connection.request("POST", "/recover", body=b"ok")
            response = connection.getresponse()
            self.assertEqual((response.status, response.read()),
                             (200, b"ok"))
        finally:
            connection.close()

    def settled_metrics(self):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=3)
        try:
            connection.request("POST", "/metrics", body=b"")
            response = connection.getresponse()
            self.assertEqual(response.status, 200)
            self.assertEqual(json.loads(response.read()), {"pending": 1, "handlers": 1})
        finally:
            connection.close()

    def test_content_length_body_arrives_before_upload_completes(self):
        with socket.create_connection(("127.0.0.1", self.port), timeout=3) as peer:
            peer.sendall(b"POST /upload HTTP/1.1\r\nHost: localhost\r\n"
                         b"Content-Length: 9\r\n\r\nalpha")
            self.next_marker()
            peer.sendall(b"beta")
            self.assertEqual(self.receive(peer)[::2], (200, b"alphabeta"))

    def test_chunk_framed_body_arrives_before_upload_completes(self):
        with socket.create_connection(("127.0.0.1", self.port), timeout=3) as peer:
            peer.sendall(b"POST /upload HTTP/1.1\r\nHost: localhost\r\n"
                         b"Transfer-Encoding: chunked\r\n\r\n5\r\nalpha\r\n")
            self.next_marker()
            peer.sendall(b"4\r\nbeta\r\n0\r\n\r\n")
            self.assertEqual(self.receive(peer)[::2], (200, b"alphabeta"))

    def test_large_chunk_frame_is_bounded_and_arrives_before_request_end(self):
        body = b"z" * 70000
        with socket.create_connection(("127.0.0.1", self.port), timeout=5) as peer:
            peer.sendall(b"POST /upload HTTP/1.1\r\nHost: localhost\r\n"
                         b"Transfer-Encoding: chunked\r\n\r\n11170\r\n" + body[:65536])
            ready, _, _ = select.select([self.server.stdout], [], [], .15)
            self.assertFalse(ready, "libevent exposed an incomplete HTTP wire chunk")
            peer.sendall(body[65536:] + b"\r\n")
            self.next_marker(3)
            peer.sendall(b"0\r\n\r\n")
            self.assertEqual(self.receive(peer)[::2], (200, body))

    def test_utf8_split_across_network_chunks_is_lossless(self):
        with socket.create_connection(("127.0.0.1", self.port), timeout=3) as peer:
            peer.sendall(b"POST /utf8 HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\n\xf0\x9f")
            ready, _, _ = select.select([self.server.stdout], [], [], .15)
            self.assertFalse(ready, "an incomplete UTF-8 code point was exposed")
            peer.sendall(b"\x98\x80B")
            self.next_marker()
            self.assertEqual(self.receive(peer)[::2], (200, "😀B".encode()))

    def test_oversized_upload_is_json_and_server_recovers(self):
        for _ in range(10):
            with socket.create_connection(("127.0.0.1", self.port), timeout=3) as peer:
                peer.sendall(b"POST /large HTTP/1.1\r\nHost: localhost\r\n"
                             b"Content-Length: 131073\r\n\r\n")
                status, head, body = self.receive(peer)
            self.assertEqual(status, 413)
            self.assertIn(b"content-type: application/json", head)
            self.assertEqual(json.loads(body)["error"]["code"], "payload_too_large")
        self.recovery_request()
        self.settled_metrics()

    def test_large_invalid_utf8_and_bad_continuation_are_bounded(self):
        malformed = b"\x80" * 65536
        with socket.create_connection(("127.0.0.1", self.port), timeout=4) as peer:
            peer.sendall(b"POST /invalid HTTP/1.1\r\nHost: localhost\r\n"
                         b"Content-Length: 65536\r\n\r\n" + malformed)
            status, _, body = self.receive(peer)
        self.assertEqual(status, 400)
        self.assertEqual(json.loads(body)["error"]["code"], "invalid_body")
        self.recovery_request()

        with socket.create_connection(("127.0.0.1", self.port), timeout=4) as peer:
            peer.sendall(b"POST /invalid HTTP/1.1\r\nHost: localhost\r\n"
                         b"Content-Length: 5\r\n\r\n\xf0\x9f")
            peer.sendall(b"ABC")
            status, _, body = self.receive(peer)
        self.assertEqual(status, 400)
        self.assertEqual(json.loads(body)["error"]["code"], "invalid_body")
        self.recovery_request()

    def test_disconnect_and_slow_consumer_release_for_next_request(self):
        for iteration in range(10):
            peer = socket.create_connection(("127.0.0.1", self.port), timeout=3)
            peer.sendall(b"POST /upload HTTP/1.1\r\nHost: localhost\r\nContent-Length: 100\r\n\r\nalpha")
            with self.subTest(iteration=iteration):
                self.next_marker()
            peer.close()
            time.sleep(.15)
        self.recovery_request()
        self.settled_metrics()

    def test_finish_before_body_end_cancels_transport_work(self):
        for _ in range(10):
            peer = socket.create_connection(("127.0.0.1", self.port), timeout=3)
            peer.sendall(b"POST /abandon HTTP/1.1\r\nHost: localhost\r\n"
                         b"Content-Length: 100000\r\n\r\n")
            peer.settimeout(1)
            try:
                self.assertEqual(peer.recv(1), b"")
            except ConnectionResetError:
                pass
            finally:
                peer.close()
        self.recovery_request()

        body = b"x" * 130000
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=6)
        try:
            connection.request("POST", "/slow", body=body)
            response = connection.getresponse()
            self.assertEqual((response.status, response.read()),
                             (200, body))
        finally:
            connection.close()
        self.recovery_request()
        self.settled_metrics()


if __name__ == "__main__":
    unittest.main()
