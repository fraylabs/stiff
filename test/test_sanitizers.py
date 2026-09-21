"""Prove the diagnostic build catches real faults; never run these uninstrumented."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


class SanitizerChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="stiff-sanitizers-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.binary = Path(cls.temporary.name) / "canary"
        result = subprocess.run([str(ROOT / "scripts/build-native.sh"),
                                 "test/fixtures/sanitizer-canary.bend", str(cls.binary)],
                                cwd=ROOT, text=True, capture_output=True, timeout=60)
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr)

    def check_fault(self, mode, diagnostic):
        result = subprocess.run([str(self.binary), mode], capture_output=True, text=True,
                                env={"PATH": "/nonexistent"}, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(diagnostic, result.stderr)

    def test_address_checks_detect_heap_overflow(self):
        self.check_fault("0", "AddressSanitizer: heap-buffer-overflow")

    def test_undefined_checks_detect_signed_overflow(self):
        self.check_fault("1", "runtime error: signed integer overflow")


def load_tests(loader, tests, pattern):
    if os.environ.get("STIFF_NATIVE_SANITIZE") not in ("1", "combined"):
        return unittest.TestSuite()
    return tests
