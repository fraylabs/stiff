#!/usr/bin/env python3
"""Native SQLite edge checks against an independent Python schedule."""
from concurrent.futures import ThreadPoolExecutor
import importlib.util
import json
import os
from pathlib import Path
import random
import queue
import sqlite3
import subprocess
import threading
import time
import tempfile
import unittest
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('ledger_http', ROOT / 'examples/ledger/test_ledger.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)
fixture.BINARY = ROOT / '.cache/bookings/bookings'

class BookingsHTTP(unittest.TestCase):
    start = fixture.LedgerHTTP.start
    stop = fixture.LedgerHTTP.stop

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='bookings-', dir=os.environ.get('TMPDIR'))
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.db = self.directory / 'bookings.db'
        self.log = (self.directory / 'server.log').open('w+')
        self.addCleanup(self.log.close)
        self.process = None
        self.addCleanup(self.stop)
        self.start()

    def call(self, method, path='/bookings', body=None, headers=None, raw=None):
        data = raw if raw is not None else json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(self.url + path, data=data, method=method,
            headers={'Content-Type': 'application/json', **(headers or {})})
        try:
            response = urllib.request.urlopen(request, timeout=10)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            payload = response.read()
            return response.status, json.loads(payload) if payload else None, dict(response.headers)

    def snapshot(self):
        status, body, _ = self.call('GET')
        self.assertEqual(status, 200, body)
        bookings = body['bookings']
        for i, a in enumerate(bookings):
            for b in bookings[i+1:]:
                self.assertFalse(a['room'] == b['room'] and a['start'] < b['end'] and b['start'] < a['end'], (a, b))
        return body

    def book(self, key=1, version=1, room=0, start=10, end=20):
        return dict(idempotency_key=key, expected_version=version, room=room, start=start, end=end)

    def cancel(self, key, version, booking_id, credential=True):
        return self.call('POST', '/admin/cancellations',
            dict(idempotency_key=key, expected_version=version, id=booking_id),
            {'X-Demo-Access': 'allowed'} if credential else {})

    def test_half_open_enclosure_and_rooms(self):
        self.assertEqual(self.snapshot()['bookings'], [])
        self.assertEqual(self.call('POST', body=self.book())[0], 200)
        before = self.snapshot()
        for start, end in ((5, 25), (15, 25), (11, 19), (10, 20), (5, 11)):
            self.assertEqual(self.call('POST', body=self.book(2, 2, 0, start, end))[0], 422)
            self.assertEqual(self.snapshot(), before)
        for key, room, start, end in ((2, 0, 20, 30), (3, 0, 0, 10), (4, 1, 10, 20)):
            self.assertEqual(self.call('POST', body=self.book(key, key, room, start, end))[0], 200)
        self.assertEqual(len(self.snapshot()['bookings']), 4)

    def test_cancel_exact_retry_cannot_resurrect_restart(self):
        first = self.book()
        self.assertEqual(self.call('POST', body=first)[0], 200)
        self.assertEqual(self.call('POST', body=self.book(2, 2, 1))[0], 200)
        before = self.snapshot()
        self.assertEqual(self.cancel(1, 3, 1, False)[0], 401)
        self.assertEqual(self.snapshot(), before)
        result = self.cancel(1, 3, 1)
        self.assertEqual(result[0], 200, result)
        self.assertEqual([b['id'] for b in result[1]['bookings']], [2])
        before = self.snapshot()
        self.assertTrue(self.cancel(1, 3, 1)[1]['replayed'])
        self.assertEqual(self.snapshot(), before)
        self.stop(kill=True)
        self.start()
        self.assertTrue(self.call('POST', body=first)[1]['replayed'])
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(self.cancel(1, 3, 2)[0], 409)

    def test_routes_reads_schema_and_key_conflicts(self):
        request = self.book()
        self.assertEqual(self.call('POST', body=request)[0], 200)
        before = self.snapshot()
        self.assertEqual(self.call('HEAD')[0], 200)
        self.assertEqual(self.call('GET', '/absent')[0], 404)
        status, body, headers = self.call('DELETE')
        self.assertEqual(status, 405)
        self.assertEqual({k.lower(): v for k, v in headers.items()}['allow'], 'GET, HEAD, POST')
        for change in ({'start': 20, 'end': 10}, {'start': 10, 'end': 10}, {'room': 3},
                       {'idempotency_key': 0}, {'end': 1441}, {'extra': 1}, {'start': 0.5}):
            self.assertEqual(self.call('POST', body=self.book(2, 2) | change)[0], 422)
        self.assertEqual(self.call('POST', raw=b'{')[0], 400)
        self.assertEqual(self.call('POST', body=request | {'end': 21})[0], 409)
        self.assertTrue(self.call('POST', body=dict(reversed(list(request.items()))))[1]['replayed'])
        self.assertEqual(self.snapshot(), before)

    def test_version_and_identical_retry_races(self):
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda key: self.call('POST', body=self.book(key, room=key-1)), [1, 2]))
        self.assertEqual(sorted(r[0] for r in results), [200, 409], results)
        self.assertEqual(len(self.snapshot()['bookings']), 1)
        request = self.book(3, 2, 2)
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda _: self.call('POST', body=request), range(2)))
        self.assertEqual([r[0] for r in results], [200, 200], results)
        self.assertEqual(sorted(r[1]['replayed'] for r in results), [False, True])
        self.assertEqual(self.snapshot()['version'], 3)

    def test_two_process_overlap_and_reordered_retry_races(self):
        peer = subprocess.Popen([str(fixture.BINARY), '--threads', '2', str(self.db), '0'],
            cwd=self.directory, env={**os.environ, 'PATH': '/nonexistent'},
            stdout=subprocess.PIPE, stderr=self.log, text=True)
        try:
            lines = queue.Queue()
            threading.Thread(target=lambda: lines.put(peer.stdout.readline()), daemon=True).start()
            line = lines.get(timeout=10)
            self.assertTrue(line.startswith('LISTENING '), line)
            peer_url = f'http://127.0.0.1:{int(line.split()[1])}/bookings'
            def send(url, body):
                request = urllib.request.Request(url, json.dumps(body).encode(),
                    headers={'Content-Type': 'application/json'}, method='POST')
                try:
                    response = urllib.request.urlopen(request, timeout=10)
                except urllib.error.HTTPError as error:
                    response = error
                with response:
                    return response.status, json.load(response)
            with ThreadPoolExecutor(max_workers=2) as pool:
                for left, right, statuses in [
                    (self.book(1), self.book(2), [200, 409]),
                    (self.book(3, 2, 1), dict(reversed(list(self.book(3, 2, 1).items()))), [200, 200])
                ]:
                    with sqlite3.connect(self.db, timeout=5) as blocker:
                        blocker.execute('BEGIN IMMEDIATE')
                        futures = [pool.submit(send, self.url + '/bookings', left), pool.submit(send, peer_url, right)]
                        time.sleep(0.15)
                        blocker.commit()
                        results = [future.result(timeout=10) for future in futures]
                    self.assertEqual(sorted(r[0] for r in results), statuses, results)
                    if statuses == [200, 200]:
                        self.assertEqual(sorted(r[1]['replayed'] for r in results), [False, True])
            self.assertEqual(len(self.snapshot()['bookings']), 2)
            self.assertEqual(self.snapshot()['version'], 3)
        finally:
            if peer.poll() is None:
                peer.terminate()
            peer.wait(timeout=10)
            peer.stdout.close()
            self.assertEqual(peer.returncode, 0)

    def test_receipt_capacity_and_retry(self):
        for key in range(1, 1001):
            result = self.cancel(key, key, 1)
            self.assertEqual(result[0], 200, (key, result))
        before = self.snapshot()
        self.assertEqual(before['version'], 1001)
        self.assertEqual(before['bookings'], [])
        self.assertEqual(self.cancel(1001, 1001, 1)[0], 409)
        self.assertEqual(self.call('POST', body=self.book(1, 1001))[0], 409)
        self.assertTrue(self.cancel(1, 1, 1)[1]['replayed'])
        self.assertEqual(self.snapshot(), before)

    def test_seeded_history_against_independent_schedule(self):
        rng = random.Random(842)
        expected = []
        version = 1
        for key in range(1, 61):
            if expected and key % 5 == 0:
                target = rng.choice(expected)['id']
                result = self.cancel(key, version, target)
                self.assertEqual(result[0], 200, result)
                expected = [b for b in expected if b['id'] != target]
                version += 1
            else:
                room = rng.randrange(3)
                start = rng.randrange(60)
                end = start + rng.randrange(1, 15)
                conflict = any(b['room'] == room and start < b['end'] and b['start'] < end for b in expected)
                result = self.call('POST', body=self.book(key, version, room, start, end))
                self.assertEqual(result[0], 422 if conflict else 200, result)
                if not conflict:
                    expected.insert(0, dict(id=key, room=room, start=start, end=end))
                    version += 1
            current = self.snapshot()
            self.assertEqual(current['bookings'], expected)
            self.assertEqual(current['version'], version)
            if key % 20 == 0:
                self.stop()
                self.start()

if __name__ == '__main__':
    unittest.main(verbosity=2)
