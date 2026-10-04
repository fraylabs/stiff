#!/usr/bin/env python3
"""Optional, macOS arm64-only scoped Lean/BendTT bootstrap. No global installs."""
import hashlib
from pathlib import Path
import platform
import shutil
import urllib.request

from tasks import CACHE, ROOT, LEAN, KERNEL, heavy, run

URL = 'https://github.com/leanprover/lean4/releases/download/v4.34.0/lean-4.34.0-darwin_aarch64.tar.zst'
SHA256 = '69f263fa6e21bbc2466bbfb1affcd92479ee2714c883a07de548e099a5922932'
KERNEL_SOURCE_SHA256 = 'e15042434e73aab07ab05cea4b77b5619082c00a6d4924ea2d4a2cdec05facce'


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def main():
    if (platform.system(), platform.machine()) != ('Darwin', 'arm64'):
        raise SystemExit('This optional bootstrap pins macOS arm64 only. Build BendTT locally with Lean 4.34.0 and set BENDTT on other platforms.')
    archive = CACHE / 'lean/lean.tar.zst'
    archive.parent.mkdir(parents=True, exist_ok=True)
    if not archive.is_file() or digest(archive) != SHA256:
        download = archive.with_suffix('.download')
        print('Downloading pinned Lean 4.34.0 (535 MiB) into the worktree cache...', flush=True)
        with urllib.request.urlopen(URL, timeout=60) as response, download.open('wb') as f:
            shutil.copyfileobj(response, f)
        if digest(download) != SHA256:
            download.unlink()
            raise SystemExit('Lean archive checksum mismatch')
        download.replace(archive)
    with heavy():
        if not (LEAN / 'lean').is_file():
            result = run(['tar', '-xf', archive, '-C', archive.parent], timeout=300)
            if result['exit']:
                raise SystemExit(result['verdict'])
        source = ROOT / '.cache/toolchain/bend2/bendtt.lean'
        if digest(source) != KERNEL_SOURCE_SHA256:
            raise SystemExit('BendTT source does not match the pinned Bend 2.0.35 toolchain')
        KERNEL.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, KERNEL.parent / 'bendtt.lean')
        # Supply absolute tools; do not put Lean's bundled Clang on the API build PATH.
        for command in ([LEAN / 'lean', '-j5', '-c', 'bendtt.c', 'bendtt.lean'],
                        [LEAN / 'leanc', '-O3', '-DNDEBUG', 'bendtt.c', '-o', 'bendtt']):
            result = run(command, cwd=KERNEL.parent, timeout=600)
            if result['exit']:
                raise SystemExit(result['verdict'])
    print('Scoped kernel built. Run make verdict; tasks.py sets BENDTT explicitly.')


if __name__ == '__main__':
    main()
