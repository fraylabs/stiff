#!/usr/bin/env python3
"""Introduce two specified mistakes in temporary copies, never shipped sources.

This demonstrates the coverage of the delivered laws/tests, not a language's
maximum possible verification capability. All subprocesses are local.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent


def replace_once(source, old, new):
    if source.count(old) != 1:
        raise RuntimeError('source changed; review the mutation rather than silently patching')
    return source.replace(old, new)


def run(command):
    result = subprocess.run(list(map(str, command)), cwd=ROOT, capture_output=True,
                            text=True, timeout=120, env={**os.environ, 'BEND_NO_TELEMETRY': '1'})
    return {'exit': result.returncode, 'stdout': result.stdout, 'stderr': result.stderr}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    records = []
    with tempfile.TemporaryDirectory(prefix='mutations-', dir=ROOT / '.cache/kingdom-comparison') as temporary:
        workspace = Path(temporary)
        for mutation, commands, expected in [
            ('pass_does_not_change_turn', ['pass0'], 'ok 20 20 100 0 0 1\n'),
            ('mortgage_creates_one_gold', ['mortgage0'], 'ok 25 20 95 0 1 1\n'),
        ]:
            for language in ('bend', 'rust'):
                target = workspace / mutation / language
                shutil.copytree(HERE / language, target, ignore=shutil.ignore_patterns('__pycache__'))
                engine = target / ('engine.bend' if language == 'bend' else 'src/engine.rs')
                source = engine.read_text()
                if language == 'bend':
                    if mutation == 'pass_does_not_change_turn':
                        start = source.index('def pass0(')
                        end = source.index('def pass1(', start)
                        body = replace_once(source[start:end],
                                            'State{gold0, gold1, bank, owner, mortgaged, 1}',
                                            'State{gold0, gold1, bank, owner, mortgaged, 0}')
                        source = source[:start] + body + source[end:]
                    else:
                        source = replace_once(source, 'U32.add(gold0, 5)', 'U32.add(gold0, 6)')
                elif mutation == 'pass_does_not_change_turn':
                    source = replace_once(source, 'Action::Pass => true,',
                                          'Action::Pass => return Transition { accepted: true, state },')
                else:
                    source = replace_once(source, 'next.gold[actor] += 5;', 'next.gold[actor] += 6;')
                engine.write_text(source)
                record = {'mutation': mutation, 'language': language}
                if language == 'bend':
                    proof = run([ROOT / '.cache/toolchain/bin/bend', target / 'PROOF.bend', '--check-only'])
                    record['proof_exit'] = proof['exit']
                    record['proof_accepted'] = proof['exit'] == 0 and 'All terms check' in proof['stdout'] + proof['stderr']
                    record['proof_verdict'] = (proof['stdout'] + proof['stderr']).replace(str(workspace), '<temporary>').replace(str(ROOT), '<stiff>').strip()
                    compiled = run([ROOT / 'scripts/build-native.sh', target / 'main.bend', target / 'kingdom'])
                    test_build = run([ROOT / 'scripts/build-native.sh', target / 'tests.bend', target / 'test-binary'])
                else:
                    record['proof_accepted'] = None
                    compiled = run(['rustc', '--edition=2021', '-D', 'warnings', '-C', 'opt-level=2',
                                    target / 'src/main.rs', '-o', target / 'kingdom'])
                    test_build = run(['rustc', '--edition=2021', '-D', 'warnings', '--test', engine, '-o', target / 'test-binary'])
                if compiled['exit'] or test_build['exit']:
                    raise RuntimeError(json.dumps({'compile': compiled, 'test_build': test_build}))
                record['ordinary_compilation_accepted'] = True
                execution = run([target / 'kingdom', *commands])
                record['expected_output'] = expected
                record['actual_output'] = execution['stdout']
                record['independent_example_detected_error'] = execution['exit'] != 0 or execution['stdout'] != expected
                test_run = run([target / 'test-binary'])
                record['worker_tests_detected_error'] = test_run['exit'] != 0
                record['worker_test_exit'] = test_run['exit']
                records.append(record)
    payload = json.dumps({'experiments': records,
                          'interpretation': 'Shows delivered proof/test coverage only; not language limits or a bug-free claim.'}, indent=2) + '\n'
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(payload)
    print(payload, end='')
    if not all(item['independent_example_detected_error'] and item['worker_tests_detected_error'] for item in records):
        raise SystemExit('A seeded mistake escaped the required behavioral checks.')


if __name__ == '__main__':
    main()
