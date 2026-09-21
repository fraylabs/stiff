"""Deterministically replay libevent's retained callback after reply reclamation."""
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent

class StreamCallbackTests(unittest.TestCase):
    def test_retained_callback_survives_reclaimed_waiter_and_checks_drain(self):
        with tempfile.TemporaryDirectory(prefix='stiff-callback-lifetime-') as temporary:
            directory = Path(temporary)
            build = subprocess.run([str(ROOT/'scripts/build-native.sh'),
                                    'test/fixtures/stream-server.bend', str(directory/'generated')],
                                   cwd=ROOT,capture_output=True,text=True,timeout=120)
            self.assertEqual(build.returncode,0,build.stdout+build.stderr)
            shutil.copy2(ROOT/'test/fixtures/stream-callback-lifetime.c', directory/'check.c')
            pkg = ROOT/'.cache/libevent/lib/pkgconfig'
            flags = shlex.split(subprocess.check_output(
                ['pkg-config','--cflags','--libs','--static','libevent_extra'],text=True,
                env={**os.environ,'PKG_CONFIG_PATH':str(pkg),'PKG_CONFIG_LIBDIR':str(pkg)}))
            flags += shlex.split(subprocess.check_output(
                ['pkg-config','--cflags','--libs','libcurl','json-c'],text=True))
            sanitizer = os.environ.get('STIFF_NATIVE_SANITIZE','0')
            checks = []
            if sanitizer != '0':
                checks = ['-fsanitize='+('address,undefined' if sanitizer in ('1','combined') else sanitizer),
                          '-fno-sanitize-recover=all','-fno-omit-frame-pointer','-g']
            compiled = subprocess.run([os.environ.get('CC','clang'),'-std=c11','-O1','-fbracket-depth=1024',
                                       *checks,str(directory/'check.c'),'-lpthread','-lm',*flags,
                                       '-o',str(directory/'check')],capture_output=True,text=True,timeout=120)
            self.assertEqual(compiled.returncode,0,compiled.stdout+compiled.stderr)
            result = subprocess.run([str(directory/'check')],capture_output=True,text=True,timeout=5)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            self.assertEqual(result.stdout.strip(),'retained callback lifetime and drain checks passed')
            self.assertEqual(result.stderr,'')
