#!/usr/bin/env python3
"""Reject routing mutations with both universal proofs and false witnesses."""
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parent.parent
BEND = os.environ.get('BEND', str(ROOT / '.cache/toolchain/bin/bend'))
ENV = {**os.environ, 'BEND_NO_TELEMETRY': '1'}
CACHE = ROOT / '.cache/routing-mistakes'


def check(source):
    p = subprocess.run([BEND, str(source), '--check-only'], cwd=ROOT,
                       env=ENV, capture_output=True, text=True, timeout=180)
    return {'exit': p.returncode, 'verdict': p.stdout + p.stderr}


def accepted(result):
    return (result['exit'] == 0 and 'ALL PROOFS CHECK' in result['verdict'].splitlines()
            and 'SOME PROOFS FAIL' not in result['verdict'] and 'Error:' not in result['verdict'])


def rejected(result):
    return ('SOME PROOFS FAIL' in result['verdict'] and
            re.search(r'Location: [^\n]+', result['verdict']) is not None)


def main():
    for name in ('PROOF.bend', 'ROUTING_WITNESSES.bend'):
        result = check(ROOT / 'src' / name)
        if not accepted(result):
            raise SystemExit(result['verdict'])
    original = (ROOT / 'src/contracts.bend').read_text()
    witnesses = (ROOT / 'src/ROUTING_WITNESSES.bend').read_text()
    mutants = [
        ('case-insensitive-get', 'case_sensitive_method',
         'String.eq(verb, method)',
         'Bool.or(String.eq(verb, method), Bool.and(String.eq(verb, "GET"), String.eq(method, "get")))'),
        ('empty-capture', 'empty_capture_rejected',
         'Bool.and(Bool.not(String.is_empty(name)), Bool.not(String.is_empty(value)))',
         'Bool.not(String.is_empty(name))'),
        ('last-match-wins', 'first_route_wins',
         'case True{}: Found{route, params}',
         'case True{}: last_choice(rest, route, params)'),
        ('duplicate-allow', 'allow_last_occurrence_order',
         'unique(has_method(method, methods), method, methods)',
         'method <> methods'),
    ]
    records = []
    for name, law, before, after in mutants:
        workspace = CACHE / name
        workspace.mkdir(parents=True, exist_ok=True)
        if original.count(before) != 1:
            raise SystemExit('Mutation target changed: ' + name)
        mutated = original.replace(before, after)
        if name == 'last-match-wins':
            helper = '''def last_choice(rest: Selection, route: Route, params: List<&2, Param>) -> Selection:
  match rest:
    case Found{chosen, captured}: Found{chosen, captured}
    case Missing{}: Found{route, params}
    case WrongMethod{methods}: Found{route, params}

'''
            mutated = mutated.replace('def chosen(', helper + 'def chosen(')
        (workspace / 'contracts.bend').write_text(mutated)
        for filename in ('routing_spec.bend', 'ROUTING_PROOF.bend'):
            (workspace / filename).write_text((ROOT / 'src' / filename).read_text())
        start = witnesses.index('law ' + law + ':')
        end = witnesses.find('\nlaw ', start + 1)
        witness = witnesses[:witnesses.index('law ')] + witnesses[start:end if end != -1 else len(witnesses)]
        (workspace / 'witness.bend').write_text(witness)
        typed = check(workspace / 'contracts.bend')
        if typed['exit'] or 'Error:' in typed['verdict'] or 'SOME PROOFS FAIL' in typed['verdict']:
            raise SystemExit('Mutation is not an ordinary well-typed program:\n' + typed['verdict'])
        generic = check(workspace / 'ROUTING_PROOF.bend')
        concrete = check(workspace / 'witness.bend')
        if not rejected(generic) or not rejected(concrete):
            raise SystemExit('Expected genuine proof and witness failure:\n' + generic['verdict'] + concrete['verdict'])
        if f'Location: {law}\n' not in concrete['verdict']:
            raise SystemExit('Rejection did not identify the intended witness:\n' + concrete['verdict'])
        records.append({'mutation': name, 'witness': law, 'ordinary_typecheck': typed,
                        'universal_proof': generic, 'concrete_witness': concrete,
                        'caught': True, 'binary_built': False})
        print(f'{name}: CAUGHT: {law} (universal proof and concrete witness)', flush=True)
    # Cache evidence is reproducible and excludes machine-specific paths.
    data = json.dumps({'experiments': records}, indent=2).replace(str(ROOT), '<stiff>')
    (CACHE / 'mutations.json').write_text(data + '\n')


if __name__ == '__main__':
    main()
