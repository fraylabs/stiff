"""Native parameter-routing and nested-schema application journeys."""
import http.client
import json
import os
from pathlib import Path
import queue
import signal
import subprocess
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parent.parent

class SchemaTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='stiff-schema-')
        cls.addClassCleanup(cls.temp.cleanup)
        cls.binary = Path(cls.temp.name) / 'api'
        subprocess.run([str(ROOT/'scripts/build-native.sh'), 'examples/validated-api.bend', str(cls.binary)],
                       cwd=ROOT, check=True, capture_output=True, timeout=120)

    def setUp(self):
        self.server = subprocess.Popen([str(self.binary), '127.0.0.1', '0'], cwd=self.temp.name,
                                       env={**os.environ, 'PATH': '/nonexistent'}, stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, text=True)
        self.addCleanup(self.stop)
        lines = queue.Queue()
        threading.Thread(target=lambda: lines.put(self.server.stdout.readline()), daemon=True).start()
        self.port = int(lines.get(timeout=5).split()[1])

    def stop(self):
        self.server.send_signal(signal.SIGTERM)
        try:
            out, err = self.server.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            self.server.kill(); out, err = self.server.communicate()
        self.assertEqual(self.server.returncode, 0, out+err)
        self.assertEqual(err, '')

    def request(self, value=None, path='/items/abc', method='POST', raw=None):
        conn = http.client.HTTPConnection('127.0.0.1', self.port, timeout=5)
        try:
            conn.request(method, path, body=raw if raw is not None else json.dumps(value),
                         headers={'Content-Type': 'application/json'})
            reply = conn.getresponse()
            return reply.status, {k.lower():v for k,v in reply.getheaders()}, json.loads(reply.read())
        finally:
            conn.close()

    def test_routing_raw_parameters_and_method_set(self):
        for token in ['abc', '123', '%2F', '%E2%98%83']:
            self.assertEqual(self.request(path='/items/'+token+'?x=1', method='GET')[2], {'id': token})
        for path in ['/items/', '/items/a/', '/items/a/b', '/Items/a', '/items']:
            self.assertEqual(self.request(path=path, method='GET')[0], 404)
        status, headers, body = self.request(method='PUT')
        self.assertEqual(status, 405)
        self.assertEqual(set(headers['allow'].split(', ')), {'GET', 'POST'})
        self.assertEqual(body['error']['code'], 'method_not_allowed')

    def test_nested_optional_nullable_and_unicode(self):
        for value in [dict(name='🌱'*40, enabled=False, count=100),
                      dict(name='a', enabled=True, count=1, note=None, tags=['x','y'], profile={'label':'ok'}),
                      dict(name='b', enabled=False, count=2, note='', tags=[])]:
            status, _, body = self.request(value)
            self.assertEqual((status, body), (200, value))

    def test_validation_paths_types_bounds_and_unknown_fields(self):
        base = dict(name='ok', enabled=True, count=1)
        cases = [({'enabled':True,'count':1}, ['name'], 'required'),
                 ({**base,'name':''}, ['name'], 'length'),
                 ({**base,'name':'🌱'*41}, ['name'], 'length'),
                 ({**base,'enabled':1}, ['enabled'], 'type'),
                 ({**base,'count':0}, ['count'], 'range'),
                 ({**base,'count':101}, ['count'], 'range'),
                 ({**base,'count':1.5}, ['count'], 'integer'),
                 ({**base,'count':-1}, ['count'], 'integer'),
                 ({**base,'count':4294967296}, ['count'], 'integer'),
                 ({**base,'count':'1'}, ['count'], 'type'),
                 ({**base,'note':False}, ['note'], 'type'),
                 ({**base,'tags':['ok','']}, ['tags','1'], 'length'),
                 ({**base,'tags':['x']*5}, ['tags'], 'length'),
                 ({**base,'profile':{}}, ['profile','label'], 'required'),
                 ({**base,'profile':{'label':'x','secret':1}}, ['profile','secret'], 'unknown'),
                 ({**base,'extra':1}, ['extra'], 'unknown'),
                 ([], [], 'type')]
        for value, path, reason in cases:
            with self.subTest(value=value):
                status, _, body = self.request(value)
                self.assertEqual(status, 422)
                self.assertEqual(body['error']['path'], path)
                self.assertEqual(body['error']['reason'], reason)
        # The parser normalizes -0 to 0 before schema validation; zero is out of
        # range here, rather than an invalid unsigned integer representation.
        status, _, body = self.request(raw='{"name":"ok","enabled":true,"count":-0}')
        self.assertEqual(status,422)
        self.assertEqual(body['error']['reason'],'range')
        status, _, body = self.request(raw='{"broken":')
        self.assertEqual(status, 400)
        self.assertEqual(body['error']['code'], 'invalid_json')
