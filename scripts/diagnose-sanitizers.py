#!/usr/bin/env python3
"""Compare pinned Bend calling conventions with ordinary C under sanitizers."""
import json
import os
from pathlib import Path
import platform
import subprocess

ROOT = Path(__file__).resolve().parent.parent
DIRECTORY = ROOT / ".cache/sanitizer-probe"
DIRECTORY.mkdir(parents=True, exist_ok=True)
report = {
    "platform": platform.platform(),
    "compiler": subprocess.check_output([os.environ.get("CC", "clang"), "--version"], text=True),
    "bend_pin": "2.0.20",
    "results": [],
}
for abi in ("compiler", "standard"):
    for sanitizer in ("address", "undefined", "combined"):
        output = DIRECTORY / f"{abi}-{sanitizer}"
        env = {**os.environ, "STIFF_NATIVE_ABI": abi, "STIFF_NATIVE_SANITIZE": sanitizer}
        build = subprocess.run([str(ROOT / "scripts/build-native.sh"),
                                "test/fixtures/native-runtime-smoke.bend", str(output)],
                               cwd=ROOT, env=env, text=True, capture_output=True, timeout=60)
        result = {"abi": abi, "sanitizer": sanitizer, "build_exit": build.returncode}
        if build.returncode:
            result["stderr"] = build.stderr
        else:
            run = subprocess.run([str(output)], cwd=ROOT, text=True, capture_output=True,
                                 timeout=15, env={"PATH": "/nonexistent"})
            result.update(exit=run.returncode, stdout=run.stdout, stderr=run.stderr)
        report["results"].append(result)
        print(json.dumps(result), flush=True)
path = DIRECTORY / "report.json"
path.write_text(json.dumps(report, indent=2) + "\n")
print(f"Report: {path}")
# Raw compiler-profile failures are diagnostic results, never hidden/suppressed.
# The standard profile must actually run the smoke program without diagnostics.
raise SystemExit(0 if all(r.get("exit") == 0 and r.get("stdout") == "runtime smoke\n"
                         and not r.get("stderr") for r in report["results"]
                         if r["abi"] == "standard") else 1)
