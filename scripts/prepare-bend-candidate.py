#!/usr/bin/env python3
"""Relax exact version expectations only in a disposable release-tracking copy."""
import argparse
from pathlib import Path
import re

from setup import VERSION

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('version')
    args = parser.parse_args()
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', args.version):
        parser.error('Expected a numeric Bend release version')
    # Do not change published consumer/BendHub pins or production source layouts.
    for name in ('scripts/build-native.sh', 'scripts/package.py',
                 'test/test_package.py', 'scripts/diagnose-sanitizers.py'):
        path = ROOT / name
        content = path.read_text()
        if VERSION not in content:
            raise RuntimeError(f'Missing expected pin in {name}; review candidate preparation')
        path.write_text(content.replace(VERSION, args.version))
    print(f'Disposable checkout prepared for Bend {args.version}; supported pin is unchanged')


if __name__ == '__main__':
    main()
