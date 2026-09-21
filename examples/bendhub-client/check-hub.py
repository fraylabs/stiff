#!/usr/bin/env python3
"""Verify every native/Bend package byte before compilation, including cache hits."""
import hashlib
import os
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent
manifest = (ROOT / 'package.manifest').read_bytes()
package = '0x' + hashlib.sha256(manifest).hexdigest()[:32]
imports = set(re.findall(r'^import (0x[0-9a-f]{32})/', (ROOT / 'main.bend').read_text(), re.MULTILINE))
if imports != {package}:
    raise SystemExit('main.bend imports do not match package.manifest; review both pins.')
cache = Path(os.environ.get('BEND_LIB', str(ROOT / '.bend/lib'))) / package
for line in manifest.decode().splitlines():
    digest, name = line.split(' ', 1)
    path = Path(name)
    if path.is_absolute() or '..' in path.parts or not re.fullmatch(r'[0-9a-f]{64}', digest):
        raise SystemExit('Invalid pinned manifest entry.')
    try:
        actual = hashlib.sha256((cache / path).read_bytes()).hexdigest()
    except FileNotFoundError:
        raise SystemExit(f'Missing cached package file: {name}; use an empty project package cache.')
    if actual != digest:
        raise SystemExit(f'Cached package differs from pinned manifest: {name}; inspect it before rebuilding.')
print(f'Verified all cached package bytes: {package}')
