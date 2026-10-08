#!/usr/bin/env python3
"""Install the pinned standalone Bend release into this checkout only."""
import argparse
import hashlib
import json
import re
import shutil
import os
from pathlib import Path
import platform
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

VERSION = "2.0.36"
DIGESTS = {
    "darwin-arm64": "2876687ceb0aba836abc98b3f62c8fc9fb612d124ae2af6814d5ec937760878d",
    "darwin-x64": "925bb306c60260e1cdde56c2b8e4ba0e1eb4cbc88a76372cc0bb389a172dccdf",
    "linux-arm64": "a14a311e39bad45f9669d4eab39d156b578c945f13a2b7bae20d9c23567a4664",
    "linux-x64": "02089dc0eed0fd5fd6d73c74cc9cffcb2c6638dd3b02ae83f7b8cc57fbe381ba",
}
ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / ".cache"
DESTINATION = CACHE / "toolchain"


def verify(directory, version=VERSION):
    result = subprocess.run([str(directory / "bin/bend"), "version"], check=True,
                            capture_output=True, text=True,
                            env={**os.environ, "BEND_NO_TELEMETRY": "1"})
    if result.stdout.strip() != f"bend {version}":
        raise RuntimeError("Unexpected Bend compiler version")


def release_metadata(version, target):
    """Resolve candidate integrity without changing the supported compiler pin."""
    url = f"https://api.github.com/repos/bendlang/bend/releases/tags/v{version}"
    headers = {"Accept": "application/vnd.github+json", "User-Agent": "stiff-release-tracking"}
    if os.environ.get("GH_TOKEN"):
        headers["Authorization"] = "Bearer " + os.environ["GH_TOKEN"]
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=60) as response:
        release = json.load(response)
    name = f"bend-{version}-{target}.tar.gz"
    asset = next((a for a in release["assets"] if a["name"] == name), None)
    if asset is None:
        raise RuntimeError(f"Bend {version} has no asset for {target}")
    digest = None
    integrity = "unpinned"
    # Prefer upstream checksum files when supplied. A present but invalid file
    # is an error, never permission to silently fall back to unverified bytes.
    checksums = [a for a in release["assets"] if a["name"].lower() in
                 (name.lower() + ".sha256", "sha256sums", "sha256sums.txt", "checksums.txt")]
    for checksum in checksums:
        with urllib.request.urlopen(checksum["browser_download_url"], timeout=60) as response:
            lines = response.read().decode("utf-8").splitlines()
        for line in lines:
            match = re.fullmatch(r"([a-fA-F0-9]{64})(?:\s+\*?(.+))?", line.strip())
            if match and (match[2] == name or (match[2] is None and checksum["name"] == name + ".sha256")):
                digest, integrity = match[1].lower(), "release-checksum-asset"
        if digest:
            break
    if checksums and not digest:
        raise RuntimeError(f"No valid checksum for {name} in release checksum assets")
    if not digest and asset.get("digest"):
        if not re.fullmatch(r"sha256:[a-fA-F0-9]{64}", asset["digest"]):
            raise RuntimeError(f"Unexpected release digest: {asset['digest']}")
        digest, integrity = asset["digest"][7:].lower(), "github-release-asset-digest"
    if not digest:
        print(f"WARNING: UNPINNED Bend {version}: no upstream checksum; recording downloaded SHA-256 only", file=sys.stderr)
    return asset["browser_download_url"], digest, {
        "version": version, "target": target, "release_url": release["html_url"],
        "source_commitish": release["target_commitish"], "integrity": integrity,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release-tracking-version", help="CI candidate only; requires a disposable checkout")
    args = parser.parse_args()
    version = args.release_tracking_version or VERSION
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        parser.error("Expected a numeric Bend release version")
    if sys.version_info < (3, 11, 8):
        raise RuntimeError("Setup requires Python 3.11.8+; see README Get started")
    missing = [tool for tool in ("clang", "make", "cmake", "patch", "pkg-config") if not shutil.which(tool)]
    if missing:
        raise RuntimeError("Missing native tools: " + ", ".join(missing) + "; see README Get started")
    dependencies = subprocess.run(["pkg-config", "--exists", "libcurl >= 7.85", "json-c", "sqlite3"])
    if dependencies.returncode:
        raise RuntimeError("Need libcurl >= 7.85, json-c and SQLite development files; "
                           "on macOS set README's PKG_CONFIG_PATH before setup")
    machine = {"aarch64": "arm64", "arm64": "arm64", "x86_64": "x64"}.get(platform.machine())
    target = f"{platform.system().lower()}-{machine}"
    if target not in DIGESTS:
        raise RuntimeError(f"Unsupported standalone Bend platform: {target}")
    digest = DIGESTS[target]
    url = f"https://github.com/bendlang/bend/releases/download/v{version}/bend-{version}-{target}.tar.gz"
    metadata = {"version": version, "target": target, "integrity": "repository-pin"}
    if args.release_tracking_version:
        url, digest, metadata = release_metadata(version, target)
    if DESTINATION.exists() and digest is None:
        raise RuntimeError("Unpinned candidate requires a fresh toolchain cache")
    if DESTINATION.exists():
        if (DESTINATION / ".archive-sha256").read_text().strip() != digest:
            raise RuntimeError("Existing toolchain has a different pin; refusing to overwrite it")
        verify(DESTINATION, version)
        if args.release_tracking_version:
            metadata["archive_sha256"] = digest
            (DESTINATION / ".release-metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
        print(f"Bend {version} already installed in .cache/toolchain")
    else:
        CACHE.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="install-bend-", dir=CACHE) as temporary:
            temporary = Path(temporary)
            archive = temporary / "release.tar.gz"
            with urllib.request.urlopen(url, timeout=60) as response, archive.open("wb") as output:
                while chunk := response.read(1024 * 1024):
                    output.write(chunk)
            with archive.open("rb") as source:
                actual = hashlib.file_digest(source, "sha256").hexdigest()
            if digest is not None and actual != digest:
                raise RuntimeError(f"Bend archive checksum mismatch: {actual}")
            extracted = temporary / "extracted"
            with tarfile.open(archive) as bundle:
                bundle.extractall(extracted, filter="data")
            candidates = list(extracted.rglob("bin/bend"))
            if len(candidates) != 1:
                raise RuntimeError("Unexpected Bend release layout")
            installation = candidates[0].parent.parent
            verify(installation, version)
            (installation / ".archive-sha256").write_text(actual + "\n")
            metadata["archive_sha256"] = actual
            (installation / ".release-metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
            installation.rename(DESTINATION)
        print(f"Installed Bend {version} in .cache/toolchain ({metadata['integrity']})")
    subprocess.run([sys.executable, str(ROOT / "scripts/setup-libevent.py")], check=True)


if __name__ == "__main__":
    main()
