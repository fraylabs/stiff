"""Exercise module-scoped foreign ids and the current native CLI contract."""
from pathlib import Path
import subprocess
import tempfile
import unittest
from scripts.test_env import sanitizer_env

ROOT = Path(__file__).resolve().parent.parent


class CompilerCompatibilityTests(unittest.TestCase):
    def test_foreign_constructor_names_and_native_argument_head(self):
        with tempfile.TemporaryDirectory(prefix="stiff-abi-") as temporary:
            binary = Path(temporary) / "abi"
            built = subprocess.run([str(ROOT / "scripts/build-native.sh"),
                                    "test/fixtures/native-abi.bend", str(binary)],
                                   cwd=ROOT, capture_output=True, text=True, timeout=120)
            self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
            for args in (["--help"], ["--", "--threads"]):
                with self.subTest(args=args):
                    result = subprocess.run([str(binary), *args], cwd=temporary,
                                            env={**sanitizer_env(), "PATH": "/nonexistent"},
                                            capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout,
                                     args[-1] + "\n5\nshadow\ntrue\n%F0%9F%8C%B1%20%26\n")
                    self.assertEqual(result.stderr, "")
