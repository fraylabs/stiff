"""A changed compiler descriptor must fail before native IO starts."""
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class AbiDescriptorTests(unittest.TestCase):
    def test_raw_http_result_rejects_changed_arity_and_hot_metadata(self):
        with tempfile.TemporaryDirectory(prefix='stiff-abi-') as temporary:
            binary = Path(temporary) / 'client'
            subprocess.run([str(ROOT / 'scripts/build-native.sh'),
                            str(ROOT / 'examples/get-json.bend'), str(binary)],
                           cwd=ROOT, check=True, capture_output=True, text=True)
            source = Path(str(binary) + '.c').read_text()
            cid = int(re.search(r'^#define CID_\w*HTTPOK (\d+)$', source, re.M)[1])
            table = re.search(r'CID_T\[\]\[2\] = \{(.*?)\};', source)
            rows = list(re.finditer(r'\{\s*\d+,\s*\d+\s*\}', table[1]))
            row = rows[cid]
            flags = shlex.split(subprocess.check_output(
                ['pkg-config', '--cflags', '--libs', 'libcurl', 'json-c'], text=True))
            for descriptor, diagnostic in (('{ 4, 0 }', 'HttpOk expected arity 3'),
                                           ('{ 3, 1 }', 'HttpOk must be non-hot')):
                with self.subTest(descriptor=descriptor):
                    changed = (source[:table.start(1) + row.start()] + descriptor +
                               source[table.start(1) + row.end():])
                    cfile = Path(temporary) / 'changed.c'
                    cfile.write_text(changed)
                    subprocess.run([os.environ.get('CC', 'clang'), '-std=c11',
                                    '-fbracket-depth=1024', '-O0', str(cfile),
                                    '-lpthread', '-lm', *flags, '-o', str(binary)],
                                   check=True, capture_output=True, text=True)
                    result = subprocess.run([str(binary), 'http://127.0.0.1:1'],
                                            capture_output=True, text=True, timeout=10)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn('Stiff ABI mismatch: ' + diagnostic, result.stderr)
