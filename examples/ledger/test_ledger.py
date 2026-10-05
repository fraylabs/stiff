#!/usr/bin/env python3
"""Exercise the compiled native API, including persistence and concurrency."""
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import socket
import sqlite3
import queue
import random
import threading
import subprocess
import tempfile
import time
import unittest
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
CACHE = ROOT / '.cache/ledger'
BINARY = Path(os.environ.get('LEDGER_BINARY', str(CACHE / 'ledger')))


class LedgerHTTP(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='http-', dir=CACHE)
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.db = self.directory / 'ledger.db'
        self.log = (self.directory / 'server.log').open('w+')
        self.addCleanup(self.log.close)
        self.process = None
        self.addCleanup(self.stop)
        self.start()

    def start(self, threads=2):
        environment = {**os.environ, 'PATH': '/nonexistent'}
        if Path('/usr/bin/atos').is_file():
            environment.update(ASAN_OPTIONS='external_symbolizer_path=/usr/bin/atos',
                               UBSAN_OPTIONS='external_symbolizer_path=/usr/bin/atos')
        self.process = subprocess.Popen([str(BINARY), '--threads', str(threads), str(self.db), '0'],
                                        cwd=self.directory, env=environment,
                                        stdout=subprocess.PIPE, stderr=self.log, text=True)
        lines = queue.Queue()
        threading.Thread(target=lambda: lines.put(self.process.stdout.readline()), daemon=True).start()
        line = lines.get(timeout=10).strip()
        self.assertTrue(line.startswith('LISTENING '), line)
        self.port = int(line.split()[1])
        self.url = f'http://127.0.0.1:{self.port}'

    def stop(self, kill=False):
        if not self.process:
            return
        process, self.process = self.process, None
        if process.poll() is None:
            process.kill() if kill else process.terminate()
        process.wait(timeout=10)
        process.stdout.close()
        self.assertEqual(process.returncode, -9 if kill else 0)
        self.log.seek(0)
        logs = self.log.read()
        for marker in ('ERROR: AddressSanitizer', 'ERROR: LeakSanitizer', 'runtime error:'):
            self.assertNotIn(marker, logs)
        self.log.seek(0, 2)

    def call(self, method, path, body=None, raw=None, base_url=None, headers=None):
        data = raw if raw is not None else json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request((base_url or self.url) + path, data=data, method=method,
                                     headers={'Content-Type': 'application/json', **(headers or {})})
        try:
            response = urllib.request.urlopen(req, timeout=10)
        except urllib.error.HTTPError as e:
            response = e
        with response:
            return response.status, json.load(response), dict(response.headers)

    def request(self, key=1, version=1, amount=30, source='alice', target='bob'):
        return {'idempotency_key': key, 'expected_version': version,
                'from': source, 'to': target, 'amount': amount}

    def accounts(self):
        status, body, _ = self.call('GET', '/accounts')
        self.assertEqual(status, 200, body)
        self.assertEqual(sum(body['accounts'].values()), 200)
        return body

    def test_contract_route_guard_and_allow(self):
        before = self.accounts()
        for headers in ({}, {'X-Demo-Access': 'wrong'}):
            status, body, _ = self.call('GET', '/protected/accounts', headers=headers)
            self.assertEqual(status, 401, body)
        self.assertEqual(self.call('GET', '/protected/accounts',
                                  headers={'X-Demo-Access': 'allowed'})[1], before)
        status, body, headers = self.call('DELETE', '/transfers')
        self.assertEqual(status, 405, body)
        self.assertEqual({k.lower(): v for k, v in headers.items()}['allow'], 'POST')
        self.assertEqual(self.call('GET', '/absent')[0], 404)
        self.assertEqual(self.accounts(), before)

    def test_initial_and_both_directions(self):
        self.assertEqual(self.accounts()['accounts'], {'alice': 100, 'bob': 100})
        r = self.call('POST', '/transfers', self.request())
        self.assertEqual(r[0], 200, r)
        self.assertEqual(r[1]['accounts'], {'alice': 70, 'bob': 130})
        self.assertEqual(r[1]['version'], 2)
        r = self.call('POST', '/transfers', self.request(2, 2, 50, 'bob', 'alice'))
        self.assertEqual(r[0], 200, r)
        self.assertEqual(r[1]['accounts'], {'alice': 120, 'bob': 80})
        self.assertIn('x-request-id', {k.lower(): v for k, v in r[2].items()})

    def test_drain_and_reject_preserves_complete_snapshot(self):
        self.assertEqual(self.call('POST', '/transfers', self.request(amount=100))[0], 200)
        before = self.accounts()
        r = self.call('POST', '/transfers', self.request(2, 2, 1))
        self.assertEqual(r[0], 422)
        self.assertEqual(r[1]['error']['code'], 'insufficient_funds')
        self.assertEqual(self.accounts(), before)
        self.assertEqual(self.call('GET', '/operations/2')[0], 404)

    def test_retry_after_intervening_transfer_and_restart(self):
        original = self.request()
        self.assertEqual(self.call('POST', '/transfers', original)[0], 200)
        self.assertEqual(self.call('POST', '/transfers', self.request(2, 2, 10))[0], 200)
        before = self.accounts()
        self.stop()
        self.start()
        status, body, _ = self.call('POST', '/transfers', original)
        self.assertEqual(status, 200, body)
        self.assertTrue(body['replayed'])
        self.assertEqual(body['operation'], original)
        self.assertEqual(body['accounts'], before['accounts'])
        self.assertEqual(body['version'], before['version'])
        status, receipt, _ = self.call('GET', '/operations/1')
        self.assertEqual((status, receipt), (200, {'state': 'applied', 'version': 2}))

    def test_same_key_different_input(self):
        self.assertEqual(self.call('POST', '/transfers', self.request())[0], 200)
        before = self.accounts()
        for change in ({'amount': 29}, {'expected_version': 2}, {'from': 'bob', 'to': 'alice'}):
            r = self.call('POST', '/transfers', self.request() | change)
            self.assertEqual(r[0], 409, r)
            self.assertEqual(r[1]['error']['code'], 'idempotency_conflict')
        self.assertEqual(self.accounts(), before)

    def test_reordered_json_is_same_input(self):
        original = self.request()
        self.assertEqual(self.call('POST', '/transfers', original)[0], 200)
        reordered = dict(reversed(list(original.items())))
        self.assertTrue(self.call('POST', '/transfers', reordered)[1]['replayed'])

    def test_numeric_key_and_version_boundaries(self):
        request = self.request(key=1000000)
        result = self.call('POST', '/transfers', request)
        self.assertEqual(result[0], 200, result)
        self.assertTrue(self.call('POST', '/transfers', request)[1]['replayed'])
        self.assertEqual(self.call('GET', '/operations/1000000')[:2],
                         (200, {'state': 'applied', 'version': 2}))
        self.assertEqual(self.call('POST', '/transfers', self.request(key=1000001))[0], 422)
        self.assertEqual(self.call('POST', '/transfers', self.request(2, 4294967294))[0], 409)
        self.assertEqual(self.call('POST', '/transfers', self.request(3, 4294967295))[0], 422)
        self.assertEqual(self.accounts()['accounts'], {'alice': 70, 'bob': 130})

    def test_version_race(self):
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda k: self.call('POST', '/transfers', self.request(k)), (1, 2)))
        self.assertEqual(sorted(r[0] for r in results), [200, 409], results)
        self.assertEqual(self.accounts()['accounts'], {'alice': 70, 'bob': 130})
        loser = 1 if results[0][0] == 409 else 2
        self.assertEqual(self.call('GET', f'/operations/{loser}')[0], 409)

    def test_identical_concurrent_retries(self):
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda _: self.call('POST', '/transfers', self.request()), range(2)))
        self.assertEqual([r[0] for r in results], [200, 200], results)
        self.assertEqual(sorted(r[1]['replayed'] for r in results), [False, True])
        self.assertEqual(self.accounts()['accounts'], {'alice': 70, 'bob': 130})
        self.assertEqual(self.accounts()['version'], 2)

    def test_concurrent_reordered_json_retries(self):
        # Separate native processes share SQLite. Holding its writer lock briefly
        # lets both handlers read the same prior snapshot before either commits.
        peer_log = (self.directory / 'peer.log').open('w+')
        environment = {**os.environ, 'PATH': '/nonexistent'}
        if Path('/usr/bin/atos').is_file():
            environment.update(ASAN_OPTIONS='external_symbolizer_path=/usr/bin/atos',
                               UBSAN_OPTIONS='external_symbolizer_path=/usr/bin/atos')
        peer = subprocess.Popen([str(BINARY), '--threads', '2', str(self.db), '0'],
                                cwd=self.directory, env=environment,
                                stdout=subprocess.PIPE, stderr=peer_log, text=True)
        try:
            lines = queue.Queue()
            threading.Thread(target=lambda: lines.put(peer.stdout.readline()), daemon=True).start()
            line = lines.get(timeout=10).strip()
            self.assertTrue(line.startswith('LISTENING '), line)
            peer_url = f'http://127.0.0.1:{int(line.split()[1])}'
            with ThreadPoolExecutor(max_workers=2) as pool:
                for key in range(1, 11):
                    source, target = ('alice', 'bob') if key % 2 else ('bob', 'alice')
                    original = self.request(key, key, 1, source, target)
                    reordered = dict(reversed(list(original.items())))
                    blocker = sqlite3.connect(self.db, timeout=5)
                    try:
                        blocker.execute('BEGIN IMMEDIATE')
                        futures = [pool.submit(self.call, 'POST', '/transfers', original),
                                   pool.submit(self.call, 'POST', '/transfers', reordered, base_url=peer_url)]
                        time.sleep(0.15)
                        blocker.commit()
                        results = [f.result(timeout=10) for f in futures]
                    finally:
                        blocker.close()
                    self.assertEqual([r[0] for r in results], [200, 200], (key, results))
                    self.assertEqual(sorted(r[1]['replayed'] for r in results), [False, True])
                    self.assertEqual(self.accounts()['version'], key + 1)
            self.assertEqual(self.accounts()['accounts'], {'alice': 100, 'bob': 100})
        finally:
            if peer.poll() is None:
                peer.terminate()
            peer.wait(timeout=10)
            peer.stdout.close()
            peer_log.seek(0)
            logs = peer_log.read()
            peer_log.close()
            self.assertEqual(peer.returncode, 0, logs)
            for marker in ('ERROR: AddressSanitizer', 'ERROR: LeakSanitizer', 'runtime error:'):
                self.assertNotIn(marker, logs)

    def test_lost_ack_sigkill_and_reconcile(self):
        payload = json.dumps(self.request()).encode()
        connection = socket.create_connection(('127.0.0.1', self.port), timeout=5)
        connection.sendall(b'POST /transfers HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: '
                           + str(len(payload)).encode() + b'\r\n\r\n' + payload)
        # Deliberately do not read the HTTP acknowledgement. Reconcile the durable
        # outcome before killing the process; this is not a precommit crash test.
        for _ in range(100):
            if self.call('GET', '/operations/1')[0] == 200:
                break
            time.sleep(0.02)
        else:
            self.fail('Operation never committed')
        connection.close()
        self.stop(kill=True)
        self.start()
        status, body, _ = self.call('POST', '/transfers', self.request())
        self.assertEqual(status, 200, body)
        self.assertTrue(body['replayed'])
        self.assertEqual(body['accounts'], {'alice': 70, 'bob': 130})
        self.assertEqual(body['version'], 2)

    def test_invalid_requests_and_routes(self):
        before = self.accounts()
        for change in ({'amount': 0}, {'amount': -1}, {'amount': 201}, {'amount': 1.5},
                       {'idempotency_key': 0}, {'expected_version': 0}, {'extra': 'field'},
                       {'from': 'alice', 'to': 'alice'}, {'from': 'carol'}):
            r = self.call('POST', '/transfers', self.request() | change)
            self.assertEqual(r[0], 422, (change, r))
        self.assertEqual(self.call('POST', '/transfers', raw=b'{')[0], 400)
        self.assertEqual(self.call('PUT', '/transfers', self.request())[0], 405)
        self.assertEqual(self.call('GET', '/missing')[0], 404)
        self.assertEqual(self.accounts(), before)

    def test_conflicting_key_race(self):
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda a: self.call('POST', '/transfers', self.request(amount=a)), (20, 30)))
        self.assertEqual(sorted(r[0] for r in results), [200, 409], results)
        winner = results[0] if results[0][0] == 200 else results[1]
        self.assertEqual(self.accounts()['accounts'], winner[1]['accounts'])
        self.assertEqual(self.accounts()['version'], 2)

    def test_seeded_history_against_independent_accounting(self):
        rng = random.Random(419)
        expected = {'alice': 100, 'bob': 100}
        version = 1
        successful = []
        for key in range(1, 61):
            source, target = ('alice', 'bob') if rng.randrange(2) else ('bob', 'alice')
            amount = rng.randint(1, 200)
            request = self.request(key, version, amount, source, target)
            status, body, _ = self.call('POST', '/transfers', request)
            if expected[source] >= amount:
                self.assertEqual(status, 200, body)
                expected[source] -= amount
                expected[target] += amount
                version += 1
                successful.append(request)
            else:
                self.assertEqual(status, 422, body)
            current = self.accounts()
            self.assertEqual(current['accounts'], expected)
            self.assertEqual(current['version'], version)
            if successful and key % 7 == 0:
                retry = self.call('POST', '/transfers', rng.choice(successful))
                self.assertEqual(retry[0], 200, retry)
                self.assertTrue(retry[1]['replayed'])
                self.assertEqual(retry[1]['accounts'], expected)
                self.assertEqual(self.accounts()['version'], version)
            if key in (20, 40):
                self.stop(kill=True)
                self.start()

    def test_receipt_capacity_and_retry_at_capacity(self):
        for key in range(1, 1001):
            source, target = ('alice', 'bob') if key % 2 else ('bob', 'alice')
            result = self.call('POST', '/transfers', self.request(key, key, 1, source, target))
            self.assertEqual(result[0], 200, (key, result))
        before = self.accounts()
        result = self.call('POST', '/transfers', self.request(1001, 1001, 1))
        self.assertEqual(result[0], 409, result)
        self.assertEqual(result[1]['error']['code'], 'ledger_full')
        self.assertEqual(self.accounts(), before)
        result = self.call('POST', '/transfers', self.request(1, 1, 1))
        self.assertEqual(result[0], 200, result)
        self.assertTrue(result[1]['replayed'])
        self.assertEqual(self.accounts(), before)


if __name__ == '__main__':
    unittest.main(verbosity=2)
