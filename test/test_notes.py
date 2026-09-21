"""Native persistent HTTP application journeys, including uncertain outcomes."""
from concurrent.futures import ThreadPoolExecutor
import http.client
import json
import os
from pathlib import Path
import queue
import signal
import socket
import subprocess
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parent.parent


class NotesTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix='stiff-notes-build-')
        cls.addClassCleanup(cls.build.cleanup)
        cls.binary = Path(cls.build.name) / 'notes'
        result = subprocess.run([str(ROOT / 'scripts/build-native.sh'),
                                 'examples/notes.bend', str(cls.binary)],
                                cwd=ROOT, capture_output=True, text=True, timeout=600)
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr)
        cls.binary.with_suffix('.c').unlink()

    def setUp(self):
        self.state = tempfile.TemporaryDirectory(prefix='stiff-notes-state-')
        self.addCleanup(self.state.cleanup)
        self.database = Path(self.state.name) / 'notes.db'
        self.server = None
        self.addCleanup(self.stop)
        self.start()

    def start(self):
        self.server = subprocess.Popen(
            [str(self.binary), '--threads', '2', str(self.database), '0'],
            cwd=self.state.name, env={**os.environ, 'PATH': '/nonexistent'},
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        lines = queue.Queue()
        threading.Thread(target=lambda: lines.put(self.server.stdout.readline()), daemon=True).start()
        line = lines.get(timeout=10).strip()
        self.assertTrue(line.startswith('LISTENING '), line)
        self.port = int(line.split()[1])

    def stop(self, kill=False):
        if self.server is None:
            return
        server, self.server = self.server, None
        if server.poll() is None:
            server.send_signal(signal.SIGKILL if kill else signal.SIGTERM)
        try:
            out, err = server.communicate(timeout=6)
        except subprocess.TimeoutExpired:
            server.kill()
            out, err = server.communicate()
            self.fail('server failed to stop: ' + out + err)
        self.assertEqual(server.returncode, -signal.SIGKILL if kill else 0, out + err)
        for marker in ('ERROR: AddressSanitizer', 'ERROR: LeakSanitizer', 'runtime error:'):
            self.assertNotIn(marker, err)
        return err

    def request(self, method, path, payload=None, raw=None):
        connection = http.client.HTTPConnection('127.0.0.1', self.port, timeout=8)
        try:
            body = json.dumps(payload) if payload is not None else raw
            connection.request(method, path, body=body,
                               headers={'Content-Type': 'application/json'})
            response = connection.getresponse()
            return response.status, json.loads(response.read()), {name.lower(): value for name, value in response.getheaders()}
        finally:
            connection.close()

    def mutation(self, operation, version=0, title='First note'):
        return {'operation_id': operation, 'expected_version': version,
                'note': {'title': title, 'done': False, 'tags': ['native', 'durable']}}

    def test_create_update_restart_and_observability(self):
        self.assertEqual(self.request('PUT', '/notes/first', self.mutation('create'))[:2],
                         (200, {'version': 1, 'replayed': False}))
        status, result, headers = self.request('GET', '/notes/first')
        self.assertEqual(status, 200)
        self.assertEqual(result, {'version': 1, 'note': self.mutation('create')['note']})
        self.assertIn('x-request-id', headers)
        self.assertEqual(self.request('PUT', '/notes/first', self.mutation('update', 1, 'Changed'))[:2],
                         (200, {'version': 2, 'replayed': False}))
        self.assertEqual(self.request('GET', '/metrics')[0], 200)
        logs = self.stop()
        self.assertIn('"event":"handler_result"', logs)
        self.start()
        self.assertEqual(self.request('GET', '/notes/first')[1]['note']['title'], 'Changed')
        self.assertEqual(self.request('GET', '/operations/update')[:2],
                         (200, {'state': 'applied', 'key': 'first', 'version': 2}))

    def test_schema_routes_and_transport_errors_share_envelope(self):
        for payload, path in [
            ({}, ['operation_id']),
            ({**self.mutation('a'), 'expected_version': -1}, ['expected_version']),
            ({**self.mutation('a'), 'expected_version': 4294967295}, ['expected_version']),
            ({**self.mutation('a'), 'note': {'title': '', 'done': False}}, ['note', 'title']),
            ({**self.mutation('a'), 'note': {'title': 'a', 'done': 'no'}}, ['note', 'done']),
            ({**self.mutation('a'), 'note': {'title': 'a', 'done': False, 'tags': [3]}}, ['note', 'tags', '0']),
            ({**self.mutation('a'), 'extra': True}, ['extra']),
        ]:
            with self.subTest(payload=payload):
                status, result, _ = self.request('PUT', '/notes/first', payload)
                self.assertEqual(status, 422)
                self.assertEqual(result['error']['code'], 'validation_failed')
                self.assertEqual(result['error']['path'], path)
        for method, path, expected in [('GET', '/missing', 404), ('POST', '/notes/first', 405),
                                       ('GET', '/notes/first', 404), ('GET', '/operations/absent', 404)]:
            status, body, _ = self.request(method, path)
            self.assertEqual(status, expected)
            self.assertEqual(set(body['error']), {'code', 'message'})
        self.assertEqual(self.request('PUT', '/notes/first', raw='{')[0], 400)
        status, body, _ = self.request('PUT', '/notes/first', raw=b'\xff')
        self.assertEqual(status, 400)
        self.assertEqual(set(body['error']), {'code', 'message'})
        self.assertEqual(self.request('PUT', '/notes/absent', self.mutation('max-version', 4294967294))[0], 409)

    def test_idempotency_and_version_conflicts_survive_restart(self):
        payload = self.mutation('same')
        self.assertEqual(self.request('PUT', '/notes/id', payload)[0], 200)
        self.assertEqual(self.request('PUT', '/notes/id', payload)[1], {'version': 1, 'replayed': True})
        self.assertEqual(self.request('PUT', '/notes/id', self.mutation('same', title='different'))[1]['error']['code'], 'idempotency_conflict')
        self.assertEqual(self.request('PUT', '/notes/id', self.mutation('stale'))[0], 409)
        self.stop(kill=True)
        self.start()
        self.assertEqual(self.request('PUT', '/notes/id', payload)[1], {'version': 1, 'replayed': True})
        self.assertEqual(self.request('GET', '/operations/stale')[1]['state'], 'version_conflict')
        self.assertEqual(self.request('GET', '/notes/id')[1]['version'], 1)

    def test_concurrent_updates_have_one_winner(self):
        self.request('PUT', '/notes/race', self.mutation('seed'))
        with ThreadPoolExecutor(max_workers=2) as pool:
            futures = [pool.submit(self.request, 'PUT', '/notes/race', self.mutation(f'race-{n}', 1, f'Note {n}')) for n in range(2)]
            results = [future.result() for future in futures]
        self.assertEqual(sorted(result[0] for result in results), [200, 409])
        self.assertEqual(self.request('GET', '/notes/race')[1]['version'], 2)

    def test_unicode_operation_id_fits_store_byte_limit(self):
        self.assertEqual(self.request('PUT', '/notes/unicode', self.mutation('😀' * 63))[0], 200)
        status, result, _ = self.request('PUT', '/notes/unicode', self.mutation('😀' * 64, 1))
        self.assertEqual(status, 422)
        self.assertEqual(result['error']['path'], ['operation_id'])
        status, result, _ = self.request('GET', '/notes/' + 'x' * 64)
        self.assertEqual(status, 422)
        self.assertEqual(result['error']['code'], 'validation_failed')

    def test_lost_http_acknowledgement_reconciles_after_process_kill(self):
        payload = self.mutation('uncertain')
        body = json.dumps(payload).encode()
        peer = socket.create_connection(('127.0.0.1', self.port), timeout=3)
        peer.sendall(b'PUT /notes/recovered HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: '
                     + str(len(body)).encode() + b'\r\n\r\n' + body)
        # Do not consume the write response. Reconcile through its durable receipt.
        try:
            deadline = time.monotonic() + 5
            while self.request('GET', '/operations/uncertain')[0] != 200:
                self.assertLess(time.monotonic(), deadline)
                time.sleep(.02)
            self.stop(kill=True)
        finally:
            peer.close()
        self.start()
        self.assertEqual(self.request('GET', '/operations/uncertain')[:2],
                         (200, {'state': 'applied', 'key': 'recovered', 'version': 1}))
        self.assertEqual(self.request('PUT', '/notes/recovered', payload)[1], {'version': 1, 'replayed': True})
        self.assertEqual(self.request('GET', '/notes/recovered')[1]['version'], 1)


if __name__ == '__main__':
    unittest.main()
