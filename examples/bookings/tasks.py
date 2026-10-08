#!/usr/bin/env python3
"""Proof and native gates; reuse the ledger's optional heavy-work lock."""
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
spec = importlib.util.spec_from_file_location('ledger_tasks', ROOT / 'examples/ledger/tasks.py')
shared = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shared)
BEND, ENV, run, accepted, heavy = shared.BEND, shared.ENV, shared.run, shared.accepted, shared.heavy
CACHE = ROOT / '.cache/bookings'

def check():
    if run([BEND, 'version'])['verdict'].strip() != 'bend 2.0.36':
        raise SystemExit('Bookings require pinned Bend 2.0.36.')
    for source in (ROOT / 'src/PROOF.bend', HERE / 'PROOF.bend'):
        r = run([BEND, source, '--check-only'])
        print(r['verdict'], end='', flush=True)
        if not accepted(r):
            raise SystemExit('Proof gate failed: no service binary will be built.')
    return r

def mistakes():
    check()
    source = (HERE / 'witnesses.bend').read_text()
    baseline = run([BEND, HERE / 'witnesses.bend', '--check-only'])
    if not accepted(baseline):
        raise SystemExit(baseline['verdict'])
    names = ['half_open_boundary', 'enclosing_slot_rejected', 'same_room_rejected',
             'cancel_exact_instance', 'retry_once_instance', 'get_no_write_instance']
    records = []
    for patch, name in zip(sorted((HERE / 'mistakes').glob('*.patch')), names, strict=True):
        workspace = CACHE / 'mistakes' / patch.stem
        workspace.mkdir(parents=True, exist_ok=True)
        for path in HERE.glob('*.bend'):
            (workspace / path.name).write_text(path.read_text().replace('../../src/', './'))
        for filename in ('contracts.bend', 'CONTRACTS_PROOF.bend',
                         'routing_spec.bend', 'ROUTING_PROOF.bend'):
            shutil.copyfile(ROOT / 'src' / filename, workspace / filename)
        applied = run(['patch', '--batch', '--fuzz=0', '-p0', '-i', patch], workspace)
        if applied['exit']:
            raise SystemExit(applied['verdict'])
        typed = run([BEND, workspace / 'http.bend', '--check-only'])
        if typed['exit'] or 'Error:' in typed['verdict']:
            raise SystemExit('Invalid ordinary program: ' + typed['verdict'])
        generic = run([BEND, workspace / 'PROOF.bend', '--check-only'])
        start = source.index('law ' + name + ':')
        end = source.find('\nlaw ', start + 1)
        imports = source[:source.index('law ')]
        witness = imports + source[start:end if end != -1 else len(source)]
        (workspace / 'witness.bend').write_text(witness.replace('../../src/', './'))
        concrete = run([BEND, workspace / 'witness.bend', '--check-only'])
        caught = not accepted(generic)
        if caught == accepted(concrete):
            raise SystemExit('Witness and generic gate disagree: ' + concrete['verdict'])
        if caught and ('SOME PROOFS FAIL' not in generic['verdict'] or 'Location:' not in generic['verdict']):
            raise SystemExit('Unexpected rejection: ' + generic['verdict'])
        if caught and ('SOME PROOFS FAIL' not in concrete['verdict'] or f'Location: {name}' not in concrete['verdict']):
            raise SystemExit('Not a demonstrated concrete law failure: ' + concrete['verdict'])
        location = re.search(r'Location: ([^\n]+)', generic['verdict'])
        record = {'mutation': patch.stem, 'caught': caught, 'law_instance': name,
                  'first_failing_proof': location.group(1) if location else None,
                  'ordinary_typecheck': typed, 'proof_check': generic, 'concrete_witness': concrete,
                  'binary_built': False}
        records.append(json.loads(json.dumps(record).replace(str(ROOT), '<stiff>')))
        print(f"{patch.stem}: {'CAUGHT' if caught else 'MISSED'}: {name} (generic proof: {record['first_failing_proof']})", flush=True)
    (CACHE / 'mutations.json').write_text(json.dumps(records, indent=2) + '\n')
    if not all(r['caught'] for r in records):
        raise SystemExit('Coverage changed; inspect and report the miss.')

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
            r = run([ROOT / 'scripts/build-native.sh', HERE / 'main.bend', CACHE / 'bookings'])
        print(r['verdict'], end='')
        if r['exit']:
            raise SystemExit(r['exit'])
    elif task == 'test':
        with heavy():
            r = run([sys.executable, HERE / 'test_bookings.py'])
        print(r['verdict'], end='')
        if r['exit']:
            raise SystemExit(r['exit'])
    elif task == 'verdict':
        ENV['BENDTT'] = ENV.get('BENDTT', str(shared.KERNEL))
        r = run([BEND, HERE / 'PROOF.bend', '--verdict'])
        (CACHE / 'verdict.json').write_text(json.dumps(r, indent=2) + '\n')
        print(r['verdict'], end='')
        if not accepted(r):
            raise SystemExit('Independent kernel verdict failed.')
    else:
        raise SystemExit('Unknown task')

if __name__ == '__main__':
    main()
