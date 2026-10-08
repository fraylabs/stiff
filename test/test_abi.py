"""A changed compiler descriptor must fail before native IO starts."""
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class AbiSignatureTests(unittest.TestCase):
    def test_registration_and_callback_changes_fail_before_c_compilation(self):
        # A fake compiler emits only the ABI declarations; no native build or IO.
        version = re.search(r"!= '([^']+)'", (ROOT / 'scripts/build-native.sh').read_text())[1]
        with tempfile.TemporaryDirectory(prefix='stiff-abi-signature-') as temporary:
            directory = Path(temporary)
            bend = directory / 'bend'
            bend.write_text(f'#!{sys.executable}\n' +
                            'import os, pathlib, sys\n' +
                            f'if sys.argv[1] == "version": print({version!r})\n' +
                            'else: pathlib.Path(sys.argv[-1]).write_text(os.environ["ABI_SOURCE"])\n')
            bend.chmod(0o755)
            cc = directory / 'cc'
            cc.write_text('#!/bin/sh\n: > "$ABI_CC_CALLED"\nexit 99\n')
            cc.chmod(0o755)
            registration = 'static void io_eff(u32 cid, Effect run) {'
            callback = 'typedef Term (*Effect)(Env e, Term* f, IoWork* w);'
            for source in (registration.replace('Effect run)', 'Effect run, u32 need)') + '\n' + callback,
                           registration + '\n' + callback.replace('Term* f', 'const Term* f')):
                with self.subTest(source=source):
                    marker = directory / 'cc-called'
                    result = subprocess.run([str(ROOT / 'scripts/build-native.sh'),
                                             'unused.bend', str(directory / 'unused')],
                                            env={**os.environ, 'BEND': str(bend), 'CC': str(cc),
                                                 'ABI_SOURCE': source, 'ABI_CC_CALLED': str(marker)},
                                            capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, 1, result.stderr)
                    self.assertIn('Stiff ABI mismatch: expected io_eff(u32, Effect)', result.stderr)
                    self.assertFalse(marker.exists())


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
