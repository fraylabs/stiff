#!/usr/bin/env python3
"""Install the pinned standalone Bend release into this checkout only."""
import hashlib
import os
from pathlib import Path
import platform
import subprocess
import tarfile
import tempfile
import urllib.request

VERSION = "2.0.20"
DIGESTS = {
    "darwin-arm64": "e8da8e28ea963e4d3956b4ab80f1c1df9a8c5208dbd6ef1e3e49bb913ed0f374",
    "darwin-x64": "89b95a5de78cf3c9e76ab649ca62ee66b3e2e6e168b2baf862a0ad4e7e57f2e7",
    "linux-arm64": "0ca9183003ea2d5d52834fe4fbe36577f13254739cf32b1455888518914e8df4",
    "linux-x64": "dca589832e1645500ad258d27171ed6b5a30812bcc3088c9aedf437059be41e1",
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
        return
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


if __name__ == "__main__":
    main()
