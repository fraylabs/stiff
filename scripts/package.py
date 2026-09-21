#!/usr/bin/env python3
"""Build a platform-specific example distribution, with provenance and checksums."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import tempfile
ROOT = Path(__file__).resolve().parent.parent

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT/'.cache/dist')
    parser.add_argument('--require-clean', action='store_true', help='Refuse a dirty source tree for release distribution')
    args = parser.parse_args()
    if os.environ.get('STIFF_NATIVE_SANITIZE', '0') != '0':
        parser.error('Release packaging requires STIFF_NATIVE_SANITIZE=0; instrumented binaries need a separate runtime contract')
    dirty = bool(subprocess.check_output(['git','status','--porcelain','--untracked-files=normal'], cwd=ROOT, text=True))
    if args.require_clean and dirty:
        parser.error('Release packaging requires a clean source tree')
    args.output.mkdir(parents=True, exist_ok=True)
    version = (ROOT/'VERSION').read_text().strip()
    target = platform.system().lower()+'-'+platform.machine()
    name = f'stiff-{version}-{target}'
    with tempfile.TemporaryDirectory(prefix='stiff-package-') as temp:
        stage = Path(temp)/name
        stage.mkdir()
        subprocess.run([str(ROOT/'scripts/build-native.sh'), 'examples/app.bend', str(stage/'app')], cwd=ROOT, check=True)
        (stage/'app.c').unlink()
        subprocess.run([str(ROOT/'scripts/build-native.sh'), 'examples/notes.bend', str(stage/'notes')], cwd=ROOT, check=True)
        (stage/'notes.c').unlink()
        subprocess.run([os.environ.get('CC','clang'), '-std=c11','-O2',str(ROOT/'native/stiff-run.c'),
                        '-o',str(stage/'stiff-run')], check=True)
        for filename in ['LICENSE','VERSION']:
            shutil.copy2(ROOT/filename, stage/filename)
        shutil.copytree(ROOT/'licenses', stage/'licenses')
        shutil.copytree(ROOT/'patches', stage/'patches')
        shutil.copytree(ROOT/'examples/deploy', stage/'deploy')
        revision = subprocess.check_output(['git','rev-parse','HEAD'], cwd=ROOT, text=True).strip()
        libraries = {}
        for library in ['libcurl','json-c','sqlite3']:
            libraries[library] = subprocess.check_output(['pkg-config','--modversion',library], text=True).strip()
        libevent_pin = json.loads((ROOT/'.cache/libevent/.stiff-pin.json').read_text())
        if hashlib.sha256((stage/'licenses/Libevent.txt').read_bytes()).hexdigest() != libevent_pin['license_sha256']:
            raise RuntimeError('Packaged libevent license differs from the pinned dependency')
        metadata = {'schema_version':1, 'static_libraries':{'libevent':libevent_pin}, 'version':version,'revision':revision,'dirty':dirty,'platform':target,
                    'bend':'2.0.20','runtime_libraries':libraries,
                    'binaries':{'app':{'sanitizer':'none','bend_abi':os.environ.get('STIFF_NATIVE_ABI','compiler')},
                                'notes':{'sanitizer':'none','bend_abi':os.environ.get('STIFF_NATIVE_ABI','compiler')},
                                'stiff-run':{'sanitizer':'none','language':'C11'}},
                    'compiler':subprocess.check_output([os.environ.get('CC','clang'),'--version'],text=True).splitlines()[0]}
        (stage/'manifest.json').write_text(json.dumps(metadata,indent=2)+'\n')
        (stage/'README.txt').write_text('Stiff example API distribution, not a static executable.\n'
            'Requires the shared libraries listed in manifest.json runtime_libraries. Libevent is statically included. No Bend/Python/Node runtime.\n'
            'Run: ./stiff-run -- ./app --threads 2 127.0.0.1 8080\n'
            'GET /health with header X-Demo-Access: allowed. This gate is synthetic, not authentication.\n'
            'Persistent notes: ./stiff-run -- ./notes --threads 2 /private/application/notes.db 8080\n'
            'Notes binds to loopback only; provide authentication at your gateway before exposing it.\n'
            'See https://github.com/fraylabs/stiff for sources, API, deployment and security boundaries.\n')
        (stage/'SHA256SUMS').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+str(p.relative_to(stage))+'\n'
                                            for p in sorted(stage.rglob('*')) if p.is_file()))
        archive = args.output/(name+'.tar.gz')
        with tarfile.open(archive,'w:gz') as tar:
            tar.add(stage,arcname=name)
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        (args.output/(archive.name+'.sha256')).write_text(digest+'  '+archive.name+'\n')
        print(archive)
if __name__ == '__main__': main()
