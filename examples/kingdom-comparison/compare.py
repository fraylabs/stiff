#!/usr/bin/env python3
"""Independent finite-state behavioral comparison; no claim of formal proof.

Pass already-built native binaries. This oracle was written from PROMPT.md
before reading either worker implementation. Python stdlib, local processes only.
"""
import argparse
from collections import deque
import hashlib
import json
from pathlib import Path
import random
import subprocess

INITIAL = (20, 20, 100, 0, 0, 0)
COMMANDS = tuple(action + str(actor) for action in ('buy', 'mortgage', 'repay', 'pass') for actor in (0, 1))
INVALID = ('', 'buy2', 'BUY0', 'buy00', ' buy0', 'buy0 ', 'pass', 'repay-1', 'mortgage😀', 'reset', 'pass0\n')


def step(state, command):
    """gold0, gold1, bank, owner, mortgage, turn; rejected moves are identity."""
    if command not in COMMANDS:
        return 'error', state
    actor = int(command[-1])
    action = command[:-1]
    gold = list(state[:2])
    bank, owner, mortgage, turn = state[2:]
    if actor != turn:
        return 'error', state
    if action == 'buy':
        if actor == owner or mortgage or gold[actor] < 10:
            return 'error', state
        gold[actor] -= 10
        gold[owner] += 10
        owner = actor
    elif action == 'mortgage':
        if actor != owner or mortgage or bank < 5:
            return 'error', state
        bank -= 5
        gold[actor] += 5
        mortgage = 1
    elif action == 'repay':
        if actor != owner or not mortgage or gold[actor] < 5:
            return 'error', state
        bank += 5
        gold[actor] -= 5
        mortgage = 0
    return 'ok', (*gold, bank, owner, mortgage, 1 - turn)


def expected(commands):
    state = INITIAL
    lines = []
    for command in commands:
        status, new = step(state, command)
        assert sum(new[:3]) == 140 and min(new[:3]) >= 0
        assert new[3] in (0, 1) and new[4] in (0, 1) and new[5] in (0, 1)
        if status == 'error':
            assert new == state
        else:
            assert new[5] == 1 - state[5]
        state = new
        lines.append(' '.join(map(str, (status, *state))))
    return ''.join(line + '\n' for line in lines)


def reachable():
    paths = {INITIAL: ()}
    pending = deque([INITIAL])
    while pending:
        state = pending.popleft()
        for command in COMMANDS:
            _, new = step(state, command)
            if new not in paths:
                paths[new] = (*paths[state], command)
                pending.append(new)
                if len(paths) > 10000:
                    raise RuntimeError('unexpected state space; inspect oracle')
    return paths


def scenarios():
    paths = reachable()
    # Every command class at every reachable state, using independent prefixes.
    cases = [('empty', ())]
    for index, path in enumerate(paths.values()):
        for command in (*COMMANDS, *INVALID):
            cases.append((f'state-{index}/{command!r}', (*path, command)))
    # Longer histories exercise traversal/IO and ordering beyond isolated edges.
    for seed in range(12):
        randomizer = random.Random(seed)
        commands = tuple(randomizer.choice((*COMMANDS, 'invalid')) for _ in range(300))
        cases.append((f'history-{seed}', commands))
    return paths, cases


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bend', type=Path, required=True)
    parser.add_argument('--rust', type=Path, required=True)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--include-runtime-flags', action='store_true',
                        help='also test reserved runtime argv tokens against the literal prompt')
    args = parser.parse_args()
    paths, cases = scenarios()
    if args.include_runtime_flags:
        cases += [('runtime-delimiter', ('--',)),
                  ('runtime-threads', ('--threads', '2')),
                  ('runtime-delimiter-before-move', ('--', 'pass0'))]
    binaries = {'bend': args.bend.resolve(), 'rust': args.rust.resolve()}
    failures = []
    for label, commands in cases:
        wanted = expected(commands)
        for language, binary in binaries.items():
            try:
                result = subprocess.run([str(binary), *commands], capture_output=True, text=True, timeout=10)
                if result.returncode != 0 or result.stdout != wanted or result.stderr:
                    failures.append({'case': label, 'language': language, 'exit': result.returncode,
                                     'expected': wanted, 'actual': result.stdout, 'stderr': result.stderr})
            except subprocess.TimeoutExpired:
                failures.append({'case': label, 'language': language, 'error': 'timeout'})
            if len(failures) >= 10:
                break
        if len(failures) >= 10:
            break
    report = {'scope': 'fixed initial state; sequential CLI; finite action/state model',
              'includes_reserved_runtime_flags': args.include_runtime_flags,
              'oracle_reachable_states': len(paths),
              'command_classes_per_state': len(COMMANDS) + len(INVALID),
              'state_command_edges': len(paths) * (len(COMMANDS) + len(INVALID)),
              'scenarios_per_implementation': len(cases),
              'expected_output_lines_per_implementation': sum(len(commands) for _, commands in cases),
              'oracle_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              'prompt_sha256': hashlib.sha256(Path(__file__).with_name('PROMPT.md').read_bytes()).hexdigest(),
              'binary_sha256': {lang: hashlib.sha256(path.read_bytes()).hexdigest() for lang, path in binaries.items()},
              'passed': not failures, 'failures': failures,
              'limitations': ['No arbitrary initial-state input, concurrent requests, persistence or networking.',
                              'Finite behavioral enumeration is not a compiler-checked proof.',
                              'One paired run cannot establish a general language ranking.']}
    payload = json.dumps(report, indent=2) + '\n'
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(payload)
    print(payload, end='')
    raise SystemExit(bool(failures))


if __name__ == '__main__':
    main()
