#!/usr/bin/env python3
"""Install the pinned standalone Bend release into this checkout only."""
import hashlib
import os
from pathlib import Path
import platform
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

VERSION = "2.0.35"
DIGESTS = {
    "darwin-arm64": "2582f25057a519c330e6875798b784b727d4201f1c1f6944a105348f0eb8972e",
    "darwin-x64": "7e59da4513e32ea7526464b342344a992a56372cdf62e0c55a30e9ce26baaeef",
    "linux-arm64": "09b813073241628f590f2c2fe420299ec25e4dddd6cf3fdc49c9486339989564",
    "linux-x64": "63039d1a119f716767ac5a7d8fe0717cfacf219c6c253c35192148e0dade722f",
}
ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / ".cache"
DESTINATION = CACHE / "toolchain"


def verify(directory):
    result = subprocess.run([str(directory / "bin/bend"), "version"], check=True,
                            capture_output=True, text=True,
                            env={**os.environ, "BEND_NO_TELEMETRY": "1"})
    if result.stdout.strip() != f"bend {VERSION}":
        raise RuntimeError("Unexpected Bend compiler version")


def main():
    machine = {"aarch64": "arm64", "arm64": "arm64", "x86_64": "x64"}.get(platform.machine())
    target = f"{platform.system().lower()}-{machine}"
    if target not in DIGESTS:
        raise RuntimeError(f"Unsupported standalone Bend platform: {target}")
    digest = DIGESTS[target]
    if DESTINATION.exists():
        if (DESTINATION / ".archive-sha256").read_text().strip() != digest:
            raise RuntimeError("Existing toolchain has a different pin; refusing to overwrite it")
        verify(DESTINATION)
        print(f"Bend {VERSION} already installed in .cache/toolchain")
    else:
        CACHE.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="install-bend-", dir=CACHE) as temporary:
            temporary = Path(temporary)
            archive = temporary / "release.tar.gz"
            url = f"https://github.com/bendlang/bend/releases/download/v{VERSION}/bend-{VERSION}-{target}.tar.gz"
            with urllib.request.urlopen(url, timeout=60) as response, archive.open("wb") as output:
                while chunk := response.read(1024 * 1024):
                    output.write(chunk)
            with archive.open("rb") as source:
                actual = hashlib.file_digest(source, "sha256").hexdigest()
            if actual != digest:
                raise RuntimeError(f"Bend archive checksum mismatch: {actual}")
            extracted = temporary / "extracted"
            with tarfile.open(archive) as bundle:
                bundle.extractall(extracted, filter="data")
            candidates = list(extracted.rglob("bin/bend"))
            if len(candidates) != 1:
                raise RuntimeError("Unexpected Bend release layout")
            installation = candidates[0].parent.parent
            verify(installation)
            (installation / ".archive-sha256").write_text(digest + "\n")
            installation.rename(DESTINATION)
        print(f"Installed Bend {VERSION} in .cache/toolchain (SHA-256 verified)")
    subprocess.run([sys.executable, str(ROOT / "scripts/setup-libevent.py")], check=True)


if __name__ == "__main__":
    main()
