#!/usr/bin/env python3
"""Local build gates; Python is tooling only, never the service runtime."""
from contextlib import contextmanager
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
CACHE = ROOT / '.cache/ledger'
BEND = os.environ.get('BEND', str(ROOT / '.cache/toolchain/bin/bend'))
ENV = {**os.environ, 'BEND': BEND, 'BEND_NO_TELEMETRY': '1'}
LEAN = CACHE / 'lean/lean-4.34.0-darwin_aarch64/bin'
KERNEL = CACHE / 'kernel/bendtt'


def run(argv, cwd=ROOT, timeout=180):
    p = subprocess.run(list(map(str, argv)), cwd=cwd, env=ENV,
                       capture_output=True, text=True, timeout=timeout)
    return {'exit': p.returncode, 'verdict': p.stdout + p.stderr}


def accepted(r):
    return (r['exit'] == 0 and 'ALL PROOFS CHECK' in r['verdict'].splitlines()
            and 'SOME PROOFS FAIL' not in r['verdict'] and 'Error:' not in r['verdict'])


def check():
    version = run([BEND, 'version'])
    if version['exit'] or version['verdict'].strip() != 'bend 2.0.36':
        raise SystemExit('Ledger checks require pinned Bend 2.0.36.')
    for source in (ROOT / 'src/PROOF.bend', HERE / 'PROOF.bend'):
        print(f'Checking {source.relative_to(ROOT)}...', flush=True)
        r = run([BEND, source, '--check-only'])
        print(r['verdict'], end='')
        if not accepted(r):
            raise SystemExit('Proof gate failed: no service binary will be built.')
    return r


@contextmanager
def heavy():
    # Optional: set STIFF_HEAVY_LOCK to a directory path to serialize heavy
    # tasks across checkouts that share one machine.
    if not os.environ.get('STIFF_HEAVY_LOCK'):
        yield
        return
    lock = Path(os.environ['STIFF_HEAVY_LOCK'])
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


def mistakes():
    check()
    witness_source = (HERE / 'witnesses.bend').read_text()
    for source in ('witnesses.bend', 'http_witnesses.bend'):
        witness_gate = run([BEND, HERE / source, '--check-only'])
        if not accepted(witness_gate):
            raise SystemExit(witness_gate['verdict'])
    witness_names = ['transfer_conserves_example', 'transfer_conserves_example',
                     'insufficient_conserves_example', 'transfer_conserves_example',
                     'rejected_transfer_unchanged_example', 'same_key_twice_equals_once_example',
                     'same_key_twice_equals_once_example', 'alice_exact_debit_credit_example',
                     'replay_response_example', 'protected_accounts_example',
                     'get_no_write_example', 'declared_status_example']
    target = CACHE / 'mistakes'
    target.mkdir(parents=True, exist_ok=True)
    records = []
    for patch in sorted((HERE / 'mistakes').glob('*.patch')):
        workspace = target / patch.stem
        workspace.mkdir(exist_ok=True)
        for name in ('engine.bend', 'spec.bend', 'LAWS.bend', 'PROOF.bend',
                     'http.bend', 'HTTP_PROOF.bend'):
            content = (HERE / name).read_text().replace('../../src/', './')
            (workspace / name).write_text(content)
        for name in ('contracts.bend', 'CONTRACTS_PROOF.bend',
                     'routing_spec.bend', 'ROUTING_PROOF.bend'):
            shutil.copyfile(ROOT / 'src' / name, workspace / name)
        applied = run(['patch', '--batch', '--fuzz=0', '-p0', '-i', patch], workspace)
        if applied['exit']:
            raise SystemExit(applied['verdict'])
        typed = run([BEND, workspace / 'http.bend', '--check-only'])
        if typed['exit'] or 'Error:' in typed['verdict']:
            raise SystemExit('Mutation is not a valid ordinary program:\n' + typed['verdict'])
        r = run([BEND, workspace / 'PROOF.bend', '--check-only'])
        caught = not accepted(r)
        location = re.search(r'Location: ([^\n]+)', r['verdict'])
        if caught and ('SOME PROOFS FAIL' not in r['verdict'] or not location):
            raise SystemExit('Unexpected diagnostic; not a demonstrated law failure:\n' + r['verdict'])
        witness_name = witness_names[len(records)]
        if len(records) < 8:
            start = witness_source.index('law ' + witness_name + ':')
            end = witness_source.find('\nlaw ', start + 1)
            witness = 'import Base\nimport ./engine.bend as E\nimport ./spec.bend as S\n\n' + witness_source[start:end if end != -1 else len(witness_source)]
        else:
            http_source = (HERE / 'http_witnesses.bend').read_text()
            start = http_source.index('law ' + witness_name + ':')
            end = http_source.find('\nlaw ', start + 1)
            # Keep independent imports and the malicious handler for the GET witness.
            helper_start = http_source.index('def writing_read(')
            helper_end = http_source.index('law get_no_write_example:')
            end = end if end != -1 else len(http_source)
            segment = http_source[start:end]
            # The first witness is followed by the helper; do not duplicate it.
            segment = segment.split('def writing_read(')[0]
            witness = http_source[:http_source.index('law ')] + http_source[helper_start:helper_end] + segment
            witness = witness.replace('../../src/', './')
        (workspace / 'witness.bend').write_text(witness)
        wr = run([BEND, workspace / 'witness.bend', '--check-only'])
        if caught == accepted(wr):
            raise SystemExit('Concrete witness disagrees with generic proof gate: ' + wr['verdict'])
        record = {'mutation': patch.stem, 'failing_law_instance': witness_name if caught else None,
                  'concrete_witness': wr, 'caught': caught,
                  'first_failing_proof': location.group(1) if location else None,
                  'ordinary_typecheck': typed, 'proof_check': r,
                  'binary_built': False}
        # Normalize worktree-local generated paths in committed evidence.
        record = json.loads(json.dumps(record).replace(str(ROOT), '<stiff>'))
        records.append(record)
        label = (f"CAUGHT: {record['failing_law_instance']} (generic proof: {record['first_failing_proof']})"
                 if caught else 'MISSED (laws still check)')
        print(f'{patch.stem}: {label}', flush=True)
    (CACHE / 'mutations.json').write_text(json.dumps({'experiments': records}, indent=2) + '\n')
    expected = [True] * 12
    if [r['caught'] for r in records] != expected:
        raise SystemExit('Coverage changed: inspect evidence and update the honest table.')


def main():
    CACHE.mkdir(parents=True, exist_ok=True)
    task = sys.argv[1]
    if task == 'check':
        check()
    elif task == 'mistakes':
        mistakes()
    elif task == 'build':
        check()
        with heavy():
            r = run([ROOT / 'scripts/build-native.sh', HERE / 'main.bend', Path(os.environ.get('LEDGER_BINARY', str(CACHE / 'ledger')))])
        print(r['verdict'], end='')
        if r['exit']:
            raise SystemExit(r['exit'])
    elif task == 'verdict':
        ENV['BENDTT'] = ENV.get('BENDTT', str(KERNEL))
        if not Path(ENV['BENDTT']).is_file():
            raise SystemExit('Build a scoped kernel first: make kernel (macOS arm64), or set BENDTT.')
        # BENDTT is already built: this is a light check of our own pure files.
        r = run([BEND, HERE / 'PROOF.bend', '--verdict'], timeout=180)
        (CACHE / 'verdict.json').write_text(json.dumps(r, indent=2) + '\n')
        print(r['verdict'], end='')
        if not accepted(r):
            raise SystemExit('Independent kernel verification did not succeed.')
    elif task == 'heavy':
        with heavy():
            raise SystemExit(subprocess.call(sys.argv[2:], cwd=ROOT, env=ENV))
    else:
        raise SystemExit('Unknown task')


if __name__ == '__main__':
    main()
