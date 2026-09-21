"""Check measurement accounting and a short native overload/recovery journey."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("stiff_benchmark", ROOT / "scripts/benchmark.py")
benchmark = importlib.util.module_from_spec(spec)
spec.loader.exec_module(benchmark)


class BenchmarkTests(unittest.TestCase):
    def test_percentile_accounting_and_overflow(self):
        histogram = [0] * (benchmark.BUCKETS + 1)
        self.assertIsNone(benchmark.percentile(histogram, .99))
        histogram[1], histogram[10], histogram[-1] = 90, 9, 1
        self.assertEqual(benchmark.percentile(histogram, .5), 1)
        self.assertEqual(benchmark.percentile(histogram, .99), 10)
        self.assertIsNone(benchmark.percentile(histogram, 1))

    def test_native_measurement_overload_recovery_and_shutdown(self):
        with tempfile.TemporaryDirectory(prefix="stiff-measurement-") as directory:
            output = Path(directory) / "report.json"
            run = subprocess.run(
                ["python3", str(ROOT / "scripts/benchmark.py"), "--duration", ".2",
                 "--soak-round-seconds", ".2", "--concurrency", "1", "8",
                 "--output", str(output)], cwd=ROOT, capture_output=True, text=True, timeout=90)
            self.assertTrue(output.exists(), run.stdout + run.stderr)
            report = json.loads(output.read_text())
            self.assertEqual(run.returncode, 0, json.dumps(report) + run.stderr)
            self.assertTrue(report["passed"])
            self.assertEqual(report["environment"]["abi"], os.environ.get("STIFF_NATIVE_ABI", "compiler"))
            self.assertEqual(len(report["phases"]), 7)
            for phase in report["phases"]:
                self.assertTrue(phase["correct"], phase)
                self.assertEqual(phase["attempts"], phase["valid_responses"])
                self.assertEqual(phase["completed_responses"], sum(phase["status_counts"].values()))
                bounds = phase["latency_ms_upper_bounds"]
                self.assertLessEqual(bounds["p50"], bounds["p95"])
                self.assertLessEqual(bounds["p95"], bounds["p99"])
            self.assertEqual(report["overload_and_shutdown"]["overload_statuses"], [503] * 8)
            self.assertTrue(report["overload_and_shutdown"]["recovered"])
            self.assertEqual(report["overload_and_shutdown"]["shutdown_valid"], 2)
            self.assertEqual(report["shutdown"]["exit_code"], 0)
            self.assertTrue(report["rss_samples"])
