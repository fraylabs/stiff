#!/usr/bin/env python3
"""Verify pinned Bend's sanitizer-compatible and standard calling conventions."""
import json
import os
from pathlib import Path
import platform
import subprocess

ROOT = Path(__file__).resolve().parent.parent
DIRECTORY = Path(os.environ.get("STIFF_SANITIZER_PROBE_DIR",
                                ROOT / ".cache/sanitizer-probe"))
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
            generated = Path(str(output) + ".c").read_text()
            result.update(
                preserve_macro=("attribute" if
                    "#define PRESERVE(A) __attribute__((A))" in generated else "empty"),
                preserve_none_sites=generated.count("PRESERVE(preserve_none)"),
                preserve_most_sites=generated.count("PRESERVE(preserve_most)"),
            )
            run = subprocess.run([str(output)], cwd=ROOT, text=True, capture_output=True,
                                 timeout=15, env={"PATH": "/nonexistent"})
            result.update(exit=run.returncode, stdout=run.stdout, stderr=run.stderr)
        report["results"].append(result)
        print(json.dumps(result), flush=True)
path = DIRECTORY / "report.json"
path.write_text(json.dumps(report, indent=2) + "\n")
print(f"Report: {path}")


def expected_layout(result):
    if result["abi"] == "standard":
        return result.get("preserve_macro") == "empty"
    if result["sanitizer"] in ("address", "combined"):
        return (result.get("preserve_macro") == "attribute"
                and result.get("preserve_none_sites") == 0
                and result.get("preserve_most_sites") == 1)
    return (result.get("preserve_macro") == "attribute"
            and result.get("preserve_none_sites") == 2
            and result.get("preserve_most_sites") == 1)


raise SystemExit(0 if all(r.get("exit") == 0
                         and r.get("stdout") == "runtime smoke\n"
                         and not r.get("stderr")
                         and expected_layout(r)
                         for r in report["results"]) else 1)
