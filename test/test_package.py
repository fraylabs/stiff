"""Extracted release example runs with native libraries and no source/tools."""
import hashlib
import http.client
import json
import os
from pathlib import Path
import queue
import signal
import subprocess
import tarfile
import tempfile
import threading
import unittest
ROOT = Path(__file__).resolve().parent.parent
class PackageTests(unittest.TestCase):
    def test_archive_checksums_and_native_journey(self):
        with tempfile.TemporaryDirectory(prefix='stiff-package-test-') as directory:
            root = Path(directory)
            p = subprocess.run(['python3',str(ROOT/'scripts/package.py'),'--output',str(root)],
                               cwd=ROOT,capture_output=True,text=True,timeout=120,
                               env={**os.environ,'STIFF_NATIVE_SANITIZE':'0','STIFF_NATIVE_ABI':'compiler'})
            self.assertEqual(p.returncode,0,p.stdout+p.stderr)
            archive, = root.glob('*.tar.gz')
            self.assertEqual(hashlib.sha256(archive.read_bytes()).hexdigest(),
                             Path(str(archive)+'.sha256').read_text().split()[0])
            with tarfile.open(archive) as tar: tar.extractall(root/'unpacked',filter='data')
            stage, = (root/'unpacked').iterdir()
            for line in (stage/'SHA256SUMS').read_text().splitlines():
                digest, name = line.split()
                self.assertEqual(hashlib.sha256((stage/name).read_bytes()).hexdigest(),digest)
            manifest = json.loads((stage/'manifest.json').read_text())
            self.assertEqual(manifest['bend'],'2.0.20')
            self.assertEqual(set(manifest['runtime_libraries']),{'libcurl','json-c'})
            self.assertEqual(manifest['static_libraries']['libevent']['version'],'2.2.2-alpha')
            self.assertTrue(all(binary['sanitizer']=='none' for binary in manifest['binaries'].values()))
            server = subprocess.Popen([str(stage/'stiff-run'),'--grace-ms','500','--',str(stage/'app'),
                                       '--threads','2','127.0.0.1','0'],cwd=stage,env={**os.environ,'PATH':'/nonexistent'},
                                      stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            try:
                lines = queue.Queue()
                threading.Thread(target=lambda:lines.put(server.stdout.readline()),daemon=True).start()
                port = int(lines.get(timeout=5).split()[1])
                conn = http.client.HTTPConnection('127.0.0.1',port,timeout=3)
                try:
                    conn.request('GET','/health',headers={'X-Demo-Access':'allowed'})
                    response = conn.getresponse()
                    self.assertEqual(response.status,200)
                    self.assertEqual(json.loads(response.read()),{'status':'ok'})
                finally: conn.close()
                server.send_signal(signal.SIGTERM)
                out,err = server.communicate(timeout=4)
                self.assertEqual(server.returncode,143,out+err)
                self.assertNotIn('runtime error:',err)
                self.assertNotIn('ERROR: AddressSanitizer',err)
            finally:
                if server.poll() is None: server.kill(); server.wait()
                server.stdout.close(); server.stderr.close()

    def test_release_packaging_rejects_sanitizer_runtime_dependencies(self):
        with tempfile.TemporaryDirectory(prefix='stiff-no-sanitizer-package-') as directory:
            result = subprocess.run(['python3',str(ROOT/'scripts/package.py'),'--output',directory],
                                    cwd=ROOT,capture_output=True,text=True,timeout=5,
                                    env={**os.environ,'STIFF_NATIVE_SANITIZE':'combined'})
            self.assertNotEqual(result.returncode,0)
            self.assertIn('requires STIFF_NATIVE_SANITIZE=0',result.stderr)
            self.assertEqual(list(Path(directory).iterdir()),[])
