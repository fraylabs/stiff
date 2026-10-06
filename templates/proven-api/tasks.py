#!/usr/bin/env python3
"""Pinned setup and mandatory framework/application proof gates."""
from contextlib import contextmanager
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent
DEPENDENCY = ROOT / 'deps/stiff'
ENV = {**os.environ, 'BEND_NO_TELEMETRY': '1'}

def run(argv, timeout=300):
    return subprocess.run(list(map(str, argv)), cwd=ROOT, env=ENV,
                          capture_output=True, text=True, timeout=timeout)

def accepted(result):
    text = result.stdout + result.stderr
    return result.returncode == 0 and 'ALL PROOFS CHECK' in text.splitlines() and 'SOME PROOFS FAIL' not in text and 'Error:' not in text

def dependency():
    revision = (ROOT / 'stiff.rev').read_text().strip()
    head = run(['git', '-C', DEPENDENCY, 'rev-parse', 'HEAD'])
    dirty = run(['git', '-C', DEPENDENCY, 'status', '--porcelain', '--untracked-files=no'])
    if head.returncode or head.stdout.strip() != revision or dirty.returncode or dirty.stdout.strip():
        raise SystemExit('Dependency must be clean and exactly match stiff.rev. Run make setup.')

def bend():
    return ENV.get('BEND', str(DEPENDENCY / '.cache/toolchain/bin/bend'))

@contextmanager
def heavy():
    # Optional: set STIFF_HEAVY_LOCK to a directory path to serialize heavy
    # tasks across projects that share one machine.
    if not ENV.get('STIFF_HEAVY_LOCK'):
        yield
        return
    lock = Path(ENV['STIFF_HEAVY_LOCK'])
    announced = False
    while True:
        try:
            lock.mkdir()
            break
        except FileExistsError:
            if not announced:
                print('Waiting for shared Stiff heavy-work lock...', flush=True)
                announced = True
            time.sleep(5)
    try:
        yield
    finally:
        lock.rmdir()

def setup():
    if not DEPENDENCY.exists():
        result = run(['sh', ROOT / 'fetch-stiff.sh'])
        print(result.stdout + result.stderr, end='', flush=True)
        if result.returncode:
            raise SystemExit(result.returncode)
    dependency()
    with heavy():
        if ENV.get('STIFF_CACHE'):
            cache = Path(ENV['STIFF_CACHE']).resolve()
            # Reject an incompatible shared cache before setup can attempt an upgrade.
            spec = importlib.util.spec_from_file_location('libevent_setup', DEPENDENCY / 'scripts/setup-libevent.py')
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            if json.loads((cache / 'libevent/.stiff-pin.json').read_text()) != module.MANIFEST:
                raise SystemExit('STIFF_CACHE libevent pin differs; choose a compatible cache.')
            if not (cache / 'toolchain/.archive-sha256').is_file():
                raise SystemExit('STIFF_CACHE compiler checksum marker missing.')
            target = DEPENDENCY / '.cache'
            target.mkdir(exist_ok=True)
            for name in ('toolchain', 'libevent'):
                link = target / name
                if not link.exists() and not link.is_symlink():
                    link.symlink_to(cache / name, target_is_directory=True)
                elif link.resolve() != (cache / name).resolve():
                    raise SystemExit('Existing dependency cache differs; inspect it before changing setup.')
        result = run([sys.executable, DEPENDENCY / 'scripts/setup.py'])
    print(result.stdout + result.stderr, end='', flush=True)
    if result.returncode:
        raise SystemExit(result.returncode)

def check():
    dependency()
    version = run([bend(), 'version'])
    if version.returncode or version.stdout.strip() != 'bend 2.0.35':
        raise SystemExit('Require pinned Bend 2.0.35; run make setup.')
    for source in (DEPENDENCY / 'src/PROOF.bend', ROOT / 'PROOF.bend'):
        result = run([bend(), source, '--check-only'])
        print(result.stdout + result.stderr, end='', flush=True)
        if not accepted(result):
            raise SystemExit('Proof gate failed: no binary will be built.')

def mistakes():
    check()
    directory = ROOT / 'build/mistake'
    directory.mkdir(parents=True, exist_ok=True)
    for name in ('api.bend', 'PROOF.bend'):
        source = (ROOT / name).read_text().replace('./deps/', '../../deps/')
        if name == 'api.bend':
            source = source.replace('"hello from @NAME@"', '"goodbye from @NAME@"')
        (directory / name).write_text(source)
    typed = run([bend(), directory / 'api.bend', '--check-only'])
    result = run([bend(), directory / 'PROOF.bend', '--check-only'])
    text = result.stdout + result.stderr
    if typed.returncode or 'Error:' in typed.stdout + typed.stderr or accepted(result) or 'SOME PROOFS FAIL' not in text or 'Location: hello_contract' not in text:
        raise SystemExit('Unexpected mutation verdict: ' + text)
    print('CAUGHT: hello_contract (ordinary code checks; no mutant binary built)')
    print(text, end='')

def main():
    task = sys.argv[1]
    if task == 'setup':
        setup()
    elif task == 'check':
        check()
    elif task == 'build':
        check()
        with heavy():
            result = run([DEPENDENCY / 'scripts/build-native.sh', ROOT / 'main.bend', ROOT / 'build/@NAME@'])
        print(result.stdout + result.stderr, end='')
        if result.returncode:
            raise SystemExit(result.returncode)
    elif task == 'mistakes':
        mistakes()
    else:
        raise SystemExit('Unknown task')

if __name__ == '__main__':
    main()
