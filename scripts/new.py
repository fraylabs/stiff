#!/usr/bin/env python3
"""Create a standalone, Git-pinned proven Stiff HTTP API."""
import argparse
from pathlib import Path
import re
import shutil

ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--name', required=True)
    parser.add_argument('--dir', required=True)
    args = parser.parse_args()
    if not re.fullmatch(r'[a-z][a-z0-9_-]{0,63}', args.name):
        parser.error('NAME must start with a lowercase letter and contain only lowercase letters, digits, _ or - (64 characters maximum).')
    destination = Path(args.dir).expanduser().absolute()
    template = ROOT / 'templates/proven-api'
    # copytree refuses existing paths and preserves the fetch script executable bit.
    if destination.exists() or destination.is_symlink():
        parser.error('DIR already exists; choose a new directory.')
    shutil.copytree(template, destination, ignore=shutil.ignore_patterns('__pycache__'))
    for path in destination.rglob('*'):
        if path.is_file():
            path.write_text(path.read_text().replace('@NAME@', args.name))
    print(f'Created {destination}')
    print('Next: make -C ' + str(destination) + ' setup check build run')

if __name__ == '__main__':
    main()
