#!/usr/bin/env python3
"""Fetch a Stiff package into an empty cache and exercise native consumers.

Network-dependent release check, deliberately separate from make test.
Uses synthetic credentials and a local certificate, never an external API.
"""
import argparse
import hashlib
import http.server
import json
import os
from pathlib import Path
import re
import ssl
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.request

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('package', help='immutable BendHub 0x hash')
    parser.add_argument('--hub', default='https://hub.bend-lang.com')
    parser.add_argument('--client-binary', type=Path, help='also verify an independently built example client')
    args = parser.parse_args()
    if not re.fullmatch(r'0x[0-9a-f]{32}', args.package):
        parser.error('expected 0x followed by 32 lowercase hex digits')
    hub = args.hub.rstrip('/')
    with tempfile.TemporaryDirectory(prefix='stiff-hub-consumer-') as temporary:
        project = Path(temporary)
        cache = project / 'lib'
        env = {**os.environ, 'BEND_LIB': str(cache), 'BEND_HUB': hub,
               'BEND_NO_TELEMETRY': '1'}

        def run(command, **kwargs):
            result = subprocess.run(command, cwd=project, env=env, text=True,
                                    capture_output=True, timeout=600, **kwargs)
            if result.returncode:
                raise RuntimeError(result.stdout + result.stderr)
            return result

        # Loading the anchor fetches every published source and checks its terms.
        (project / 'check.bend').write_text(
            f'import {args.package}/stiff.bend as Stiff\n')
        bend = os.environ.get('BEND', str(ROOT / '.cache/toolchain/bin/bend'))
        checked = run([bend, 'check.bend', '--check-only'])
        if 'All terms check.' not in checked.stdout + checked.stderr:
            raise RuntimeError('package proof/type check did not report success')
        with urllib.request.urlopen(f'{hub}/{args.package}/manifest', timeout=30) as response:
            manifest = response.read()
        if '0x' + hashlib.sha256(manifest).hexdigest()[:32] != args.package:
            raise RuntimeError('manifest hash mismatch')
        entries = [line.split(' ', 1) for line in manifest.decode().splitlines()]
        expected = {'stiff.bend'} | {str(p.relative_to(ROOT)) for p in (ROOT / 'src').glob('*.bend')} | {
            str(p.relative_to(ROOT)) for p in (ROOT / 'src/effects').glob('*.c')}
        if {path for _, path in entries} != expected:
            raise RuntimeError('published file inventory differs from the library source set')
        for digest, path in entries:
            downloaded = (cache / args.package / path).read_bytes()
            if hashlib.sha256(downloaded).hexdigest() != digest:
                raise RuntimeError(f'file hash mismatch: {path}')
            if downloaded != (ROOT / path).read_bytes():
                raise RuntimeError(f'published source differs from checkout: {path}')

        for source, name, prefix in [('examples/auth-client/main.bend', 'auth-client', './deps/stiff/src/'),
                                     ('examples/notes.bend', 'notes', '../src/')]:
            (project / f'{name}.bend').write_text((ROOT / source).read_text().replace(prefix, args.package + '/src/'))
            run([str(ROOT / 'scripts/build-native.sh'), f'{name}.bend', str(project / name)])

        cert, key = project / 'cert.pem', project / 'key.pem'
        run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', str(key),
             '-out', str(cert), '-days', '1', '-subj', '/CN=localhost', '-addext',
             'subjectAltName=IP:127.0.0.1'])
        visits = []

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def do_GET(self):
                visits.append(self.headers.get('Authorization'))
                body = b'{"message":"BendHub native HTTPS verified"}'
                self.send_response(200 if visits[-1] == 'Bearer synthetic-hub-test' else 401)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert, key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        runtime_env = {**os.environ, 'STIFF_TOKEN': 'synthetic-hub-test', 'STIFF_CA_BUNDLE': str(cert),
                       'NO_PROXY': '127.0.0.1', 'no_proxy': '127.0.0.1', 'PATH': '/nonexistent'}
        client_binaries = [project / 'auth-client']
        if args.client_binary:
            client_binaries.append(args.client_binary.resolve())
        try:
            for client_binary in client_binaries:
                visits.clear()
                result = subprocess.run([str(client_binary), f'https://127.0.0.1:{server.server_port}/auth'],
                                        cwd=project, env=runtime_env, capture_output=True, text=True, timeout=15)
                if result.returncode or result.stdout.strip() != 'HTTP 200\nBendHub native HTTPS verified':
                    raise RuntimeError(result.stdout + result.stderr)
                if visits != ['Bearer synthetic-hub-test']:
                    raise RuntimeError('expected one authenticated HTTPS request')
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)

        # Reuse the application journey assertions against the hub-built binary.
        sys.path.insert(0, str(ROOT / 'test'))
        from test_notes import NotesTests

        class HubNotesTests(NotesTests):
            @classmethod
            def setUpClass(cls):
                cls.binary = project / 'notes'

        results = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(HubNotesTests))
        if not results.wasSuccessful():
            raise RuntimeError('hub-backed persistent application journeys failed')
        print(json.dumps({'package': args.package, 'hub': hub, 'files': len(entries),
                          'manifest_sha256': hashlib.sha256(manifest).hexdigest(),
                          'compiler': run([bend, 'version']).stdout.strip(),
                          'empty_cache_download': True, 'source_bytes_match': True,
                          'proof_verdict': 'All terms check.', 'native_https': 'passed',
                          'independently_built_example_https': bool(args.client_binary),
                          'persistent_application_tests': results.testsRun}, indent=2))


if __name__ == '__main__':
    main()
