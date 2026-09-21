#!/usr/bin/env python3
"""Build Stiff's pinned static libevent inside this checkout."""

import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request


VERSION = "2.2.2-alpha"
RUNTIME_VERSION = "2.2.2-alpha-dev"
PKG_VERSION = "2.2.2"
TAG = "release-2.2.2-alpha"
TAG_OBJECT = "58bc9c771db13a518362ed5803739d7942ea7650"
COMMIT = "df3ecad3a040fd6d4fad4287defe113395de6fd7"
URL = ("https://github.com/libevent/libevent/releases/download/"
       "release-2.2.2-alpha/libevent-2.2.2-alpha.tar.gz")
ARCHIVE_SHA256 = "4ab1b369bcb5af0c5971b8ade4e95a2c1326f6d0dc1ba75d620bf0331c3184a8"
LICENSE_SHA256 = "75092d5ecfeefefacc0f345b6f0172234ca580c279c537de7229597cfbfd71e7"
ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / ".cache"
DESTINATION = CACHE / "libevent"
PATCH = ROOT / "patches/libevent-error-headers.patch"
PATCH_SHA256 = "77f3200db9822c892f2eafe7ded46822add96c34fd0f4b3077f0d7d5addb6461"
PATCHED_HTTP_SHA256 = "59f58a55ad62445e93af1d83dfd1ff027bca1da68d5dbee0a75d5378da7452b3"
MANIFEST = {
    "archive_sha256": ARCHIVE_SHA256,
    "build": {
        "library_type": "STATIC",
        "openssl": False,
        "mbedtls": False,
        "position_independent_code": True,
        "tests": False,
    },
    "license_sha256": LICENSE_SHA256,
    "package_version": PKG_VERSION,
    "patches": [{
        "path": "patches/libevent-error-headers.patch",
        "sha256": PATCH_SHA256,
        "upstream_status": "local-not-submitted",
    }],
    "runtime_version": RUNTIME_VERSION,
    "source_commit": COMMIT,
    "source_tag": TAG,
    "source_tag_object": TAG_OBJECT,
    "source_url": URL,
    "version": VERSION,
}
LEGACY_MANIFEST = {key: value for key, value in MANIFEST.items() if key != "patches"}
CMAKE_OPTIONS = (
    "-DCMAKE_BUILD_TYPE=Release",
    "-DCMAKE_INSTALL_LIBDIR=lib",
    "-DCMAKE_POSITION_INDEPENDENT_CODE=ON",
    "-DEVENT__LIBRARY_TYPE=STATIC",
    "-DEVENT__DISABLE_OPENSSL=ON",
    "-DEVENT__DISABLE_MBEDTLS=ON",
    "-DEVENT__DISABLE_TESTS=ON",
    "-DEVENT__DISABLE_REGRESS=ON",
    "-DEVENT__DISABLE_BENCHMARK=ON",
    "-DEVENT__DISABLE_SAMPLES=ON",
)


def digest(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def pkg_environment(directory):
    pkgconfig = directory / "lib/pkgconfig"
    return {**os.environ, "PKG_CONFIG_PATH": str(pkgconfig),
            "PKG_CONFIG_LIBDIR": str(pkgconfig)}


def verify(directory, expected_manifest=MANIFEST):
    marker = directory / ".stiff-pin.json"
    if not marker.is_file() or json.loads(marker.read_text()) != expected_manifest:
        raise RuntimeError("Existing scoped libevent has a different or invalid pin")
    license_path = directory / "share/licenses/libevent/LICENSE"
    if not license_path.is_file() or digest(license_path) != LICENSE_SHA256:
        raise RuntimeError("Scoped libevent license is missing or changed")
    if expected_manifest == MANIFEST:
        installed_patch = directory / "share/stiff/patches/libevent-error-headers.patch"
        if (not PATCH.is_file() or digest(PATCH) != PATCH_SHA256
                or not installed_patch.is_file()
                or digest(installed_patch) != PATCH_SHA256):
            raise RuntimeError("Scoped libevent patch provenance is missing or changed")
    archives = [directory / f"lib/{name}"
                for name in ("libevent.a", "libevent_core.a", "libevent_extra.a")]
    if not all(archive.is_file() for archive in archives):
        raise RuntimeError("Scoped libevent static archives are missing")
    dynamic = [path for path in (directory / "lib").rglob("*")
               if path.is_file() and (path.suffix in (".so", ".dylib", ".dll")
                                      or ".so." in path.name)]
    if dynamic:
        raise RuntimeError("Scoped libevent unexpectedly contains shared libraries")
    event_config = (directory / "include/event2/event-config.h").read_text()
    if (f'#define EVENT__VERSION "{RUNTIME_VERSION}"' not in event_config
            or "#define EVENT__HAVE_OPENSSL" in event_config
            or "#define EVENT__HAVE_MBEDTLS" in event_config):
        raise RuntimeError("Scoped libevent version or TLS feature set is wrong")
    http_header = (directory / "include/event2/http.h").read_text()
    for symbol in ("evhttp_set_newreqcb", "evhttp_set_errorcb",
                   "evhttp_request_set_chunked_cb"):
        if symbol not in http_header:
            raise RuntimeError(f"Scoped libevent header is missing {symbol}")

    pkg_config = os.environ.get("PKG_CONFIG", "pkg-config")
    environment = pkg_environment(directory)
    version = subprocess.check_output(
        [pkg_config, "--modversion", "libevent_extra"], env=environment, text=True).strip()
    if version != PKG_VERSION:
        raise RuntimeError(f"Scoped libevent pkg-config version is {version}, not {PKG_VERSION}")
    flags = shlex.split(subprocess.check_output(
        [pkg_config, "--cflags", "--libs", "--static", "libevent_extra"],
        env=environment, text=True))
    with tempfile.TemporaryDirectory(prefix="verify-libevent-", dir=CACHE) as temporary:
        temporary = Path(temporary)
        source = temporary / "probe.c"
        executable = temporary / "probe"
        source.write_text(r'''#include <event2/buffer.h>
#include <event2/event.h>
#include <event2/http.h>
#include <stdio.h>
static int new_request(struct evhttp_request *req, void *arg) {
  (void)req; (void)arg; return 0;
}
static int error_page(struct evhttp_request *req, struct evbuffer *buffer,
                      int error, const char *reason, void *arg) {
  (void)req; (void)buffer; (void)error; (void)reason; (void)arg; return 0;
}
static void chunk(struct evhttp_request *req, void *arg) {
  (void)req; (void)arg;
}
int main(void) {
  struct evhttp *http = evhttp_new(NULL);
  struct evhttp_request *req = evhttp_request_new(NULL, NULL);
  if (http == NULL || req == NULL) return 2;
  evhttp_set_newreqcb(http, new_request, NULL);
  evhttp_set_errorcb(http, error_page, NULL);
  evhttp_request_set_chunked_cb(req, chunk);
  evhttp_request_free(req);
  evhttp_free(http);
  puts(event_get_version());
  return 0;
}
''')
        compiler = os.environ.get("CC", "clang")
        subprocess.run([compiler, "-std=c11", "-Werror", str(source), *flags,
                        "-o", str(executable)], check=True, timeout=120)
        result = subprocess.run([str(executable)], check=True, capture_output=True,
                                text=True, timeout=30)
        if result.stdout.strip() != RUNTIME_VERSION:
            raise RuntimeError("Scoped libevent runtime version is wrong")
        dependency_command = (["otool", "-L", str(executable)] if sys.platform == "darwin"
                              else ["ldd", str(executable)])
        dependency_lines = subprocess.check_output(dependency_command, text=True).splitlines()
        if sys.platform == "darwin":
            dependency_lines = dependency_lines[1:]
        dependencies = "\n".join(dependency_lines).lower()
        if "libevent" in dependencies:
            raise RuntimeError("Scoped libevent probe retained a shared libevent dependency")


def main():
    replace_legacy = False
    if DESTINATION.exists():
        marker = DESTINATION / ".stiff-pin.json"
        installed_manifest = json.loads(marker.read_text()) if marker.is_file() else None
        if installed_manifest == MANIFEST:
            verify(DESTINATION)
            print(f"libevent {VERSION} already installed in .cache/libevent (static, patched, SHA-256 verified)")
            return
        if installed_manifest != LEGACY_MANIFEST:
            raise RuntimeError("Existing scoped libevent has a different pin; refusing to replace it")
        verify(DESTINATION, LEGACY_MANIFEST)
        replace_legacy = True
    if not PATCH.is_file() or digest(PATCH) != PATCH_SHA256:
        raise RuntimeError("libevent source patch checksum mismatch")
    CACHE.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="install-libevent-", dir=CACHE) as temporary:
        temporary = Path(temporary)
        archive = temporary / "libevent.tar.gz"
        request = urllib.request.Request(URL, headers={"User-Agent": "stiff-setup/1"})
        with urllib.request.urlopen(request, timeout=60) as response, archive.open("wb") as output:
            while chunk := response.read(1024 * 1024):
                output.write(chunk)
        if digest(archive) != ARCHIVE_SHA256:
            raise RuntimeError("libevent source archive checksum mismatch")

        extracted = temporary / "source"
        extracted.mkdir()
        with tarfile.open(archive) as bundle:
            bundle.extractall(extracted, filter="data")
        sources = [path for path in extracted.iterdir()
                   if path.is_dir() and path.name == f"libevent-{VERSION}"]
        if len(sources) != 1:
            raise RuntimeError("Unexpected libevent source archive layout")
        source = sources[0]
        if digest(source / "LICENSE") != LICENSE_SHA256:
            raise RuntimeError("libevent source license differs from the pinned release")
        patch_tool = os.environ.get("PATCH", "patch")
        subprocess.run([patch_tool, "--batch", "--fuzz=0", "-p1",
                        "-i", str(PATCH)], cwd=source, check=True, timeout=30)
        if digest(source / "http.c") != PATCHED_HTTP_SHA256:
            raise RuntimeError("Patched libevent HTTP source differs from the reviewed result")

        build = temporary / "build"
        stage = temporary / "stage"
        cmake = os.environ.get("CMAKE", "cmake")
        subprocess.run([cmake, "-S", str(source), "-B", str(build),
                        f"-DCMAKE_INSTALL_PREFIX={DESTINATION}", *CMAKE_OPTIONS],
                       check=True, timeout=300)
        subprocess.run([cmake, "--build", str(build), "--parallel",
                        str(min(os.cpu_count() or 1, 8))], check=True, timeout=600)
        environment = {**os.environ, "DESTDIR": str(stage)}
        subprocess.run([cmake, "--install", str(build)], check=True,
                       env=environment, timeout=300)
        installation = stage / DESTINATION.relative_to(DESTINATION.anchor)
        if not installation.is_dir():
            raise RuntimeError("Unexpected staged libevent installation layout")
        license_destination = installation / "share/licenses/libevent/LICENSE"
        license_destination.parent.mkdir(parents=True)
        shutil.copy2(source / "LICENSE", license_destination)
        patch_destination = installation / "share/stiff/patches/libevent-error-headers.patch"
        patch_destination.parent.mkdir(parents=True)
        shutil.copy2(PATCH, patch_destination)
        (installation / ".stiff-pin.json").write_text(
            json.dumps(MANIFEST, indent=2, sort_keys=True) + "\n")
        backup = None
        if replace_legacy:
            backup_parent = CACHE / "compiler-resolution"
            backup_parent.mkdir(exist_ok=True)
            backup_root = Path(tempfile.mkdtemp(
                prefix="libevent-before-error-headers-", dir=backup_parent))
            backup = backup_root / "libevent"
            DESTINATION.rename(backup)
        installation.rename(DESTINATION)
        try:
            verify(DESTINATION)
        except Exception:
            DESTINATION.rename(temporary / "failed-installation")
            if backup is not None:
                backup.rename(DESTINATION)
            raise
    print(f"Installed libevent {VERSION} in .cache/libevent (static, patched, SHA-256 verified)")
    if backup is not None:
        print(f"Preserved the verified unpatched prefix at {backup.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
